package ru.dubbing.prompter;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Typeface;
import android.media.AudioManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.webkit.ConsoleMessage;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.SocketTimeoutException;
import java.net.URL;
import java.net.UnknownHostException;
import java.util.ArrayDeque;

/**
 * Суфлёр дубляжа: оболочка над WebView.
 * Один раз спрашивает адрес REAPER (IP:порт), дальше открывает http://IP:порт/prompter.html,
 * которую создаёт Dubbing Prompter в папке reaper_www_root. Реплики и позиция берутся из REAPER,
 * видео страница получает сама (сервер видео на ПК, порт 8765, либо копия, либо файл с телефона).
 *
 * 1.4.0: повторяющиеся ошибки в журнале сворачиваются («×N»), защита диалога диагностики при закрытом экране.
 * 1.3.0: кнопки громкости управляют громкостью мультимедиа, громкость и звук в «Диагностике».
 * 1.2.0: быстрая проверка связи перед загрузкой (понятная причина вместо минуты ожидания),
 * «Диагностика» с копированием отчёта, журнал ошибок страницы, восстановление после сбоя WebView.
 */
public class MainActivity extends Activity {

    private static final String PREFS = "dubbing_prompter";
    private static final String KEY_ADDR = "addr";
    private static final int BG = 0xFF0B0D12;
    private static final int PANEL = 0xFF1C212B;
    private static final int REQ_VIDEO = 17;
    private static final int VIDEO_PORT = 8765;
    private static final int NET_TIMEOUT_MS = 4000;

    private SharedPreferences prefs;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private FrameLayout root;
    private WebView web;
    private LinearLayout setupBox;
    private LinearLayout errorBox;
    private EditText input;
    private TextView setupMsg;
    private TextView errorText;
    private String url;
    private boolean failed;
    private int gen;                                  // номер попытки подключения: старые ответы игнорируются
    private ValueCallback<Uri[]> fileCallback;
    private final ArrayDeque<String> pageLog = new ArrayDeque<>();
    private int lastLogCount = 1;

    private final Runnable retry = new Runnable() {
        @Override
        public void run() {
            if (errorBox.getVisibility() == View.VISIBLE && url != null) {
                connect(url);
            }
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        setVolumeControlStream(AudioManager.STREAM_MUSIC);   // кнопки громкости сразу меняют громкость видео
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true);   // chrome://inspect, только в отладочной сборке
        }

        root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            applyInsets(v, insets);
            return insets;
        });

        buildWebView();
        buildSetup();
        buildError();
        setContentView(root);

        if (Build.VERSION.SDK_INT >= 33) {
            Api33.registerBack(this, this::onBackAction);
        }

        String saved = prefs.getString(KEY_ADDR, null);
        if (saved != null) {
            openUrl(saved);
        } else {
            showSetup(null);
        }
    }

    // ---------- UI ----------

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private void buildWebView() {
        web = new WebView(this);
        web.setBackgroundColor(BG);
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(false);                 // страница берётся только по сети
        s.setAllowContentAccess(true);               // нужен для выбора видео-файла на телефоне
        web.setWebViewClient(new Client());
        web.setWebChromeClient(new WebChromeClient() {
            // Кнопка «Выбрать файл на телефоне» на странице суфлёра: системный выбор файла
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback,
                                             FileChooserParams params) {
                if (fileCallback != null) fileCallback.onReceiveValue(null);
                fileCallback = callback;
                Intent i = new Intent(Intent.ACTION_GET_CONTENT);
                i.addCategory(Intent.CATEGORY_OPENABLE);
                i.setType("video/*");
                try {
                    startActivityForResult(Intent.createChooser(i, "Выберите видео"), REQ_VIDEO);
                } catch (ActivityNotFoundException e) {
                    fileCallback = null;
                    callback.onReceiveValue(null);
                    return false;
                }
                return true;
            }

            // Ошибки и предупреждения страницы попадают в «Диагностику»
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                if (m.messageLevel() == ConsoleMessage.MessageLevel.ERROR
                        || m.messageLevel() == ConsoleMessage.MessageLevel.WARNING) {
                    addLog("страница: " + m.message());
                }
                return false;
            }
        });
        root.addView(web, 0, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        web.setVisibility(View.GONE);
    }

    private TextView label(String text, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(t.getTypeface(), Typeface.BOLD);
        return t;
    }

    private Button button(String text) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(Color.WHITE);
        b.setBackgroundColor(0xFF2F4F8F);
        b.setPadding(dp(16), dp(12), dp(16), dp(12));
        return b;
    }

    private void buildSetup() {
        setupBox = new LinearLayout(this);
        setupBox.setOrientation(LinearLayout.VERTICAL);
        setupBox.setGravity(Gravity.CENTER);
        setupBox.setBackgroundColor(BG);
        setupBox.setPadding(dp(24), dp(24), dp(24), dp(24));

        setupBox.addView(label("Суфлёр дубляжа", 24, Color.WHITE, true));
        TextView hint = label("Введите адрес компьютера с REAPER: IP и порт, например 192.168.1.50:8080.\n"
                + "Адрес показывает Dubbing Prompter: Все инструменты → «Суфлёр на телефон / планшет».",
                15, 0xFF9AA3B2, false);
        hint.setPadding(0, dp(12), 0, dp(16));
        setupBox.addView(hint);

        input = new EditText(this);
        input.setHint("192.168.1.50:8080");
        input.setHintTextColor(0xFF6B7280);
        input.setTextColor(Color.WHITE);
        input.setBackgroundColor(PANEL);
        input.setPadding(dp(14), dp(12), dp(14), dp(12));
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setImeOptions(EditorInfo.IME_ACTION_GO);
        input.setOnEditorActionListener((v, actionId, event) -> {
            onConnectClicked();
            return true;
        });
        setupBox.addView(input, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        setupMsg = label("", 14, 0xFFFFB4AB, false);
        setupMsg.setPadding(0, dp(8), 0, dp(8));
        setupBox.addView(setupMsg);

        Button go = button("Подключиться");
        go.setOnClickListener(v -> onConnectClicked());
        setupBox.addView(go, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        root.addView(setupBox, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setupBox.setVisibility(View.GONE);
    }

    private void buildError() {
        errorBox = new LinearLayout(this);
        errorBox.setOrientation(LinearLayout.VERTICAL);
        errorBox.setGravity(Gravity.CENTER);
        errorBox.setBackgroundColor(BG);
        errorBox.setPadding(dp(24), dp(24), dp(24), dp(24));

        errorBox.addView(label("Нет связи с REAPER", 22, Color.WHITE, true));
        errorText = label("", 15, 0xFFFFB4AB, false);
        errorText.setPadding(0, dp(12), 0, dp(16));
        errorBox.addView(errorText);

        Button again = button("Повторить сейчас");
        again.setOnClickListener(v -> {
            handler.removeCallbacks(retry);
            retry.run();
        });
        errorBox.addView(again, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        Button diag = button("Диагностика");
        diag.setBackgroundColor(PANEL);
        diag.setOnClickListener(v -> showDiagnostics());
        LinearLayout.LayoutParams lpd = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lpd.topMargin = dp(10);
        errorBox.addView(diag, lpd);

        Button change = button("Изменить адрес");
        change.setBackgroundColor(PANEL);
        change.setOnClickListener(v -> showSetup(prefs.getString(KEY_ADDR, null)));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(10);
        errorBox.addView(change, lp);

        TextView note = label("Приложение повторяет попытку само каждые 3 секунды.", 13, 0xFF6B7280, false);
        note.setPadding(0, dp(14), 0, 0);
        errorBox.addView(note);

        root.addView(errorBox, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        errorBox.setVisibility(View.GONE);
    }

    private void showSetup(String prefill) {
        handler.removeCallbacks(retry);
        gen++;                                            // отменяет незавершённую проверку связи
        errorBox.setVisibility(View.GONE);
        web.setVisibility(View.GONE);
        setupBox.setVisibility(View.VISIBLE);
        setupMsg.setText("");
        if (prefill != null) {
            Uri u = Uri.parse(prefill);
            String hp = u.getHost() == null ? prefill : u.getHost() + (u.getPort() > 0 ? ":" + u.getPort() : "");
            input.setText(hp);
            input.setSelection(input.getText().length());
        }
        input.requestFocus();
    }

    private void showError(String text) {
        failed = true;
        errorText.setText(text);
        errorBox.setVisibility(View.VISIBLE);
        setupBox.setVisibility(View.GONE);
        handler.removeCallbacks(retry);
        handler.postDelayed(retry, 3000);
    }

    private void hideKeyboard() {
        InputMethodManager imm = (InputMethodManager) getSystemService(INPUT_METHOD_SERVICE);
        if (imm != null) imm.hideSoftInputFromWindow(input.getWindowToken(), 0);
        input.clearFocus();
    }

    // ---------- журнал ----------

    private void addLog(String line) {
        synchronized (pageLog) {
            if (line.length() > 300) line = line.substring(0, 300) + "…";
            String last = pageLog.peekLast();
            if (last != null) {
                String base = last.replaceFirst(" \\(×\\d+\\)$", "");
                if (base.equals(line)) {                 // та же ошибка подряд: не плодим строки, считаем повторы
                    lastLogCount++;
                    pageLog.removeLast();
                    pageLog.addLast(line + " (×" + lastLogCount + ")");
                    return;
                }
            }
            lastLogCount = 1;
            pageLog.addLast(line);
            while (pageLog.size() > 25) pageLog.removeFirst();
        }
    }

    private String logText() {
        StringBuilder b = new StringBuilder();
        synchronized (pageLog) {
            for (String s : pageLog) b.append("• ").append(s).append('\n');
        }
        return b.length() == 0 ? "(ошибок не было)\n" : b.toString();
    }

    // ---------- сеть ----------

    /** "192.168.1.5" -> http://192.168.1.5:8080/prompter.html; полный URL оставляет как есть. */
    static String normalize(String in) {
        String s = in == null ? "" : in.trim();
        if (s.isEmpty()) return null;
        if (!s.contains("://")) s = "http://" + s;
        Uri u = Uri.parse(s);
        String host = u.getHost();
        String scheme = u.getScheme();
        if (host == null || host.isEmpty() || scheme == null) return null;
        int port = u.getPort();
        String path = u.getPath();
        StringBuilder b = new StringBuilder();
        b.append(scheme).append("://").append(host).append(':').append(port > 0 ? port : 8080);
        if (path == null || path.isEmpty() || path.equals("/")) b.append("/prompter.html");
        else b.append(path);
        return b.toString();
    }

    /** Понятное описание сетевой ошибки. */
    static String describe(Exception e) {
        String m = String.valueOf(e.getMessage());
        String lm = m.toLowerCase();
        if (e instanceof UnknownHostException) {
            return "адрес не найден. Проверьте IP.";
        }
        if (m.contains("ECONNREFUSED") || lm.contains("refused")) {
            return "соединение отклонено: на этом адресе и порту ничего не слушает. Проверьте порт и "
                    + "включён ли веб-интерфейс REAPER (или запущен сервер видео).";
        }
        if (e instanceof SocketTimeoutException || m.contains("ETIMEDOUT") || m.contains("EHOSTUNREACH")
                || m.contains("ENETUNREACH") || lm.contains("timed out") || lm.contains("unreachable")
                || lm.contains("no route")) {
            return "нет ответа (таймаут). Чаще всего: брандмауэр Windows блокирует программу, "
                    + "телефон в другой Wi-Fi сети или неверный IP.";
        }
        return e.getClass().getSimpleName() + ": " + m;
    }

    /** Один GET. Возвращает "HTTP код: начало ответа" или описание ошибки. Только в фоновом потоке. */
    private String httpGet(String target, int maxBody) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(target).openConnection();
            c.setConnectTimeout(NET_TIMEOUT_MS);
            c.setReadTimeout(NET_TIMEOUT_MS);
            c.setUseCaches(false);
            int code = c.getResponseCode();
            String body = "";
            if (maxBody > 0) {
                InputStream in = code >= 400 ? c.getErrorStream() : c.getInputStream();
                if (in != null) {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[512];
                    int n;
                    while (out.size() < maxBody && (n = in.read(buf)) > 0) out.write(buf, 0, n);
                    in.close();
                    body = out.toString("UTF-8");
                    if (body.length() > maxBody) body = body.substring(0, maxBody);
                }
            }
            return "HTTP " + code + (body.isEmpty() ? "" : ": " + body.replace('\n', ' ').trim());
        } catch (Exception e) {
            return "ОШИБКА, " + describe(e);
        } finally {
            if (c != null) c.disconnect();
        }
    }

    /** Подключение: сначала быстрая проверка, и только потом загрузка страницы в WebView. */
    private void connect(final String target) {
        final int my = ++gen;
        new Thread(() -> {
            final String r = httpGet(target, 0);
            runOnUiThread(() -> {
                if (my != gen || isFinishing()) return;
                if (r.startsWith("HTTP 200")) {
                    failed = false;
                    web.loadUrl(target);
                } else if (r.startsWith("HTTP 404")) {
                    showError("REAPER отвечает, но страницы prompter.html нет (404).\n\nВ Dubbing Prompter "
                            + "выберите «Суфлёр на телефон / планшет» и повторите.");
                } else if (r.startsWith("HTTP ")) {
                    showError("REAPER вернул " + r + " для " + target);
                } else {
                    showError("Не удалось открыть " + target + "\n\n" + r.replace("ОШИБКА, ", "")
                            + "\n\nПроверьте: REAPER запущен; включён веб-интерфейс (Preferences → "
                            + "Control/OSC/web → Web browser interface); порт совпадает; телефон и ПК "
                            + "в одной Wi-Fi сети; брандмауэр Windows разрешает reaper.exe.");
                }
            });
        }, "dp-connect").start();
    }

    private void onConnectClicked() {
        String n = normalize(input.getText().toString());
        if (n == null) {
            setupMsg.setText("Не похоже на адрес. Пример: 192.168.1.50:8080");
            return;
        }
        prefs.edit().putString(KEY_ADDR, n).apply();
        openUrl(n);
    }

    private void openUrl(String u) {
        hideKeyboard();
        url = u;
        failed = false;
        setupBox.setVisibility(View.GONE);
        errorBox.setVisibility(View.GONE);
        web.setVisibility(View.VISIBLE);
        connect(u);
    }

    // ---------- диагностика ----------

    @SuppressWarnings("deprecation")
    private String versionText() {
        String app = "?";
        try {
            app = getPackageManager().getPackageInfo(getPackageName(), 0).versionName;
        } catch (Exception ignored) {
        }
        String wv = "?";
        try {
            PackageInfo p = WebView.getCurrentWebViewPackage();
            if (p != null) wv = p.packageName + " " + p.versionName;
        } catch (Exception ignored) {
        }
        return "Приложение " + app + ", Android " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT
                + "), WebView " + wv;
    }

    private String volumeText() {
        try {
            AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
            if (am == null) return "неизвестно";
            int v = am.getStreamVolume(AudioManager.STREAM_MUSIC);
            int m = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            return v + " из " + m + (v == 0 ? " (ЗВУК ВЫКЛЮЧЕН: прибавьте громкость кнопками телефона)" : "");
        } catch (Exception e) {
            return "неизвестно";
        }
    }

    private void showDiagnostics() {
        final String addr = prefs.getString(KEY_ADDR, null);
        if (addr == null) {
            new AlertDialog.Builder(this).setMessage("Адрес ещё не задан.").setPositiveButton("OK", null).show();
            return;
        }
        final Uri u = Uri.parse(addr);
        final String host = u.getHost() == null ? "" : u.getHost();
        final int port = u.getPort() > 0 ? u.getPort() : 8080;
        final AlertDialog wait = new AlertDialog.Builder(this).setMessage("Проверяю связь…").show();
        new Thread(() -> {
            final StringBuilder b = new StringBuilder();
            b.append(versionText()).append("\n");
            b.append("Громкость мультимедиа: ").append(volumeText()).append("\n\n");
            b.append("Адрес: ").append(addr).append("\n\n");
            b.append("1) Веб-интерфейс REAPER, позиция (:").append(port).append("/_/TRANSPORT):\n   ")
                    .append(httpGet("http://" + host + ":" + port + "/_/TRANSPORT", 80)).append("\n\n");
            b.append("2) Страница суфлёра (:").append(port).append("/prompter.html):\n   ")
                    .append(httpGet("http://" + host + ":" + port + "/prompter.html", 0)).append("\n\n");
            b.append("3) Сервер видео (:").append(VIDEO_PORT).append("/info):\n   ")
                    .append(httpGet("http://" + host + ":" + VIDEO_PORT + "/info", 400)).append("\n\n");
            b.append("Ошибки страницы:\n").append(logText());
            final String report = b.toString();
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) return;   // экран уже закрыт: диалог показывать нельзя
                wait.dismiss();
                new AlertDialog.Builder(MainActivity.this)
                        .setTitle("Диагностика")
                        .setMessage(report)
                        .setPositiveButton("Закрыть", null)
                        .setNeutralButton("Копировать", (d, w) -> {
                            ClipboardManager cm = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
                            if (cm != null) cm.setPrimaryClip(ClipData.newPlainText("diagnostics", report));
                        })
                        .show();
            });
        }, "dp-diag").start();
    }

    // ---------- навигация и результаты ----------

    private void onBackAction() {
        new AlertDialog.Builder(this)
                .setItems(new String[]{"Диагностика", "Изменить адрес", "Выйти из приложения", "Отмена"}, (d, which) -> {
                    if (which == 0) showDiagnostics();
                    else if (which == 1) showSetup(prefs.getString(KEY_ADDR, null));
                    else if (which == 2) finish();
                })
                .show();
    }

    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        // Android 12 и ниже; на 13+ работает Api33.registerBack
        onBackAction();
    }

    @Override
    @SuppressWarnings("deprecation")
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQ_VIDEO) {
            Uri[] result = null;
            if (resultCode == RESULT_OK && data != null) {
                result = WebChromeClient.FileChooserParams.parseResult(resultCode, data);
            }
            if (fileCallback != null) {
                fileCallback.onReceiveValue(result);
                fileCallback = null;
            }
            return;
        }
        super.onActivityResult(requestCode, resultCode, data);
    }

    private class Client extends WebViewClient {
        @Override
        public void onPageStarted(WebView view, String u, Bitmap favicon) {
            failed = false;
        }

        @Override
        public void onPageFinished(WebView view, String u) {
            if (!failed) {
                errorBox.setVisibility(View.GONE);
                handler.removeCallbacks(retry);
            }
        }

        @Override
        public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
            if (request.isForMainFrame()) {
                addLog("загрузка страницы: " + error.getDescription());
                showError("Не удалось открыть " + url + "\n\n" + error.getDescription()
                        + "\n\nПроверьте: REAPER запущен; включён веб-интерфейс; порт совпадает; "
                        + "телефон и ПК в одной Wi-Fi сети; брандмауэр Windows разрешает reaper.exe.");
            }
        }

        @Override
        public void onReceivedHttpError(WebView view, WebResourceRequest request, WebResourceResponse resp) {
            if (request.isForMainFrame()) {
                int code = resp.getStatusCode();
                showError(code == 404
                        ? "REAPER отвечает, но страницы prompter.html нет (404).\n\nВ Dubbing Prompter "
                        + "выберите «Суфлёр на телефон / планшет» и повторите."
                        : "REAPER вернул ошибку HTTP " + code + " для " + url);
            }
        }

        /** Процесс WebView убит системой (нехватка памяти) или упал: пересоздаём WebView, а не вылетаем. */
        @Override
        public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
            addLog("процесс WebView завершён" + (detail.didCrash() ? " (сбой)" : " (нехватка памяти)")
                    + ", страница перезапущена");
            root.removeView(web);
            web.destroy();
            buildWebView();
            if (url != null && setupBox.getVisibility() != View.VISIBLE) {
                web.setVisibility(View.VISIBLE);
                connect(url);
            }
            return true;
        }
    }

    // ---------- системные панели ----------

    @SuppressWarnings("deprecation")
    private void applyInsets(View v, WindowInsets in) {
        int l, t, r, b;
        if (Build.VERSION.SDK_INT >= 30) {
            android.graphics.Insets i = in.getInsets(WindowInsets.Type.systemBars()
                    | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
            l = i.left; t = i.top; r = i.right; b = i.bottom;
        } else {
            l = in.getSystemWindowInsetLeft(); t = in.getSystemWindowInsetTop();
            r = in.getSystemWindowInsetRight(); b = in.getSystemWindowInsetBottom();
        }
        v.setPadding(l, t, r, b);
    }

    @SuppressWarnings("deprecation")
    private void immersive() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION);
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) immersive();
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    protected void onPause() {
        web.onPause();
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        gen++;
        handler.removeCallbacksAndMessages(null);
        root.removeView(web);
        web.destroy();
        super.onDestroy();
    }
}
