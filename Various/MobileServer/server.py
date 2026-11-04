#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Сервер видео для Dubbing Prompter.

Отдаёт на телефон ОРИГИНАЛЬНЫЙ видеофайл проекта REAPER потоком (HTTP Range, перемотка),
без копирования и без перекодирования. Никакие другие файлы не раздаются:
путь к видео берётся из файла настроек, который пишет Dubbing Prompter.

Только стандартная библиотека Python 3.8+. Интернет не нужен.

  GET /info    -> JSON: {"ok":true,"name":...,"size":...,"audio":[кодеки],"proxy":bool}  или  {"ok":false,"error":"..."}
  GET /video   -> видеофайл (поддерживает Range, HEAD); /video?src=proxy -> лёгкая копия со звуком AAC
  GET /        -> страница диагностики

Запуск: start_server.bat  (или: python server.py --port 8765 --config prompter_server.json)
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from html import escape

ALLOWED = {
    '.mp4': 'video/mp4', '.m4v': 'video/mp4', '.mov': 'video/quicktime',
    '.mkv': 'video/x-matroska', '.webm': 'video/webm', '.avi': 'video/x-msvideo',
    '.mpg': 'video/mpeg', '.mpeg': 'video/mpeg', '.wmv': 'video/x-ms-wmv',
    '.mxf': 'application/mxf',
}
CHUNK = 256 * 1024
CONFIG = ''
PORT = 8765
STATS = {'start': time.time(), 'requests': 0, 'video_requests': 0, 'bytes': 0}


def log(msg):
    try:
        print(time.strftime('[%H:%M:%S] ') + msg, flush=True)
    except Exception:
        pass


def read_config(path):
    try:
        with open(path, 'r', encoding='utf-8-sig') as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, ('Файл настроек не найден: %s. В Dubbing Prompter выберите '
                      '«Суфлёр: сервер видео».' % path)
    except Exception as e:  # битый JSON, нет прав и т.п.
        return None, 'Не удалось прочитать настройки: %s' % e


def current_video(path):
    """Возвращает (путь_к_видео, None) или (None, текст_ошибки)."""
    cfg, err = read_config(path)
    if err:
        return None, err
    v = str(cfg.get('video') or '').strip()
    if not v:
        return None, 'В проекте REAPER не найден видео-элемент.'
    ext = os.path.splitext(v)[1].lower()
    if ext not in ALLOWED:
        return None, 'Тип файла не поддерживается: %s' % (ext or 'без расширения')
    if not os.path.isfile(v):
        return None, 'Видеофайл не найден: %s' % v
    return v, None


_AUDIO_CACHE = {}
_AUDIO_PENDING = set()
_AUDIO_LOCK = threading.Lock()


def find_ffprobe():
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.path.join(here, '..', 'ffprobe.exe'), os.path.join(here, 'ffprobe.exe')):
        if os.path.isfile(cand):
            return cand
    return shutil.which('ffprobe')


def _probe_worker(key, ff, path):
    codecs = None
    try:
        kw = {}
        if os.name == 'nt':
            kw['creationflags'] = 0x08000000   # CREATE_NO_WINDOW
        out = subprocess.run([ff, '-v', 'error', '-select_streams', 'a', '-show_entries',
                              'stream=codec_name', '-of', 'csv=p=0', path],
                             capture_output=True, text=True, timeout=20, **kw)
        if out.returncode == 0:
            codecs = [ln.strip().split(',')[0] for ln in out.stdout.splitlines() if ln.strip()]
    except Exception:
        codecs = None
    with _AUDIO_LOCK:
        if len(_AUDIO_CACHE) > 8:
            _AUDIO_CACHE.clear()
        _AUDIO_CACHE[key] = codecs
        _AUDIO_PENDING.discard(key)


def audio_codecs(path):
    """-> (кодеки или None, готово). [] = звука в файле нет, None = неизвестно.
    ffprobe запускается в фоне: ответ /info не ждёт его, поэтому телефон не видит задержки."""
    try:
        key = (path, os.path.getmtime(path), os.path.getsize(path))
    except OSError:
        return None, True
    with _AUDIO_LOCK:
        if key in _AUDIO_CACHE:
            return _AUDIO_CACHE[key], True
        if key in _AUDIO_PENDING:
            return None, False
        ff = find_ffprobe()
        if not ff:
            _AUDIO_CACHE[key] = None
            return None, True
        _AUDIO_PENDING.add(key)
    threading.Thread(target=_probe_worker, args=(key, ff, path), daemon=True).start()
    return None, False


def proxy_video(path):
    """Лёгкая копия (её делает Prompter через ffmpeg, со звуком AAC): путь или None."""
    cfg, err = read_config(path)
    if err:
        return None
    p = str(cfg.get('proxy') or '').strip()
    if p and os.path.splitext(p)[1].lower() in ALLOWED and os.path.isfile(p):
        return p
    return None


def parse_range(header, size):
    """None -> отдать весь файл; 'bad' -> 416; (start, end) -> 206."""
    if not header or not header.startswith('bytes='):
        return None
    spec = header[6:].strip()
    if ',' in spec:               # несколько диапазонов не поддерживаем: отдаём весь файл
        return None
    a, _, b = spec.partition('-')
    try:
        if a == '':
            n = int(b)
            if n <= 0:
                return 'bad'
            start, end = max(0, size - n), size - 1
        else:
            start = int(a)
            end = int(b) if b else size - 1
    except ValueError:
        return None               # некорректный заголовок игнорируется
    end = min(end, size - 1)
    if start < 0 or start >= size or start > end:
        return 'bad'
    return (start, end)


def local_ips():
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('10.255.255.255', 1))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            ips.add(ip)
    except OSError:
        pass
    return sorted(i for i in ips if not i.startswith('127.') and not i.startswith('169.254.'))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'DubbingVideo/1.0'

    def log_message(self, fmt, *args):   # свой краткий лог
        pass

    def _cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Range, Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
        self.send_header('Access-Control-Expose-Headers', 'Content-Range, Accept-Ranges, Content-Length')

    def _send(self, code, body, ctype, head=False, extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self._cors()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def _json(self, code, obj, head=False):
        self._send(code, json.dumps(obj, ensure_ascii=False).encode('utf-8'),
                   'application/json; charset=utf-8', head)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Content-Length', '0')
        self._cors()
        self.end_headers()

    def do_HEAD(self):
        self._route(True)

    def do_GET(self):
        self._route(False)

    def _route(self, head):
        STATS['requests'] += 1
        try:
            path = urlparse(self.path).path
            if path == '/info':
                self._info(head)
            elif path == '/video':
                self._video(head)
            elif path in ('/', '/index.html'):
                self._home(head)
            else:
                self._json(404, {'ok': False, 'error': 'Не найдено'}, head)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError):
            self.close_connection = True
        except OSError:
            self.close_connection = True

    def _info(self, head):
        v, err = current_video(CONFIG)
        if err:
            self._json(200, {'ok': False, 'error': err, 'port': PORT}, head)
            return
        st = os.stat(v)
        codecs, ready = audio_codecs(v)
        self._json(200, {'ok': True, 'name': os.path.basename(v), 'size': st.st_size,
                         'mtime': int(st.st_mtime), 'port': PORT,
                         'audio': codecs,                     # [] нет звука, None неизвестно
                         'audio_ready': ready,                # False: ffprobe ещё считает, спросите позже
                         'proxy': proxy_video(CONFIG) is not None}, head)

    def _video(self, head):
        q = parse_qs(urlparse(self.path).query)
        if (q.get('src') or [''])[0] == 'proxy':
            v = proxy_video(CONFIG)
            err = None if v else 'Лёгкая копия не найдена. В Prompter выберите «Суфлёр: видео для телефона».'
        else:
            v, err = current_video(CONFIG)
        if err:
            log('видео недоступно: ' + err)
            self._json(404, {'ok': False, 'error': err}, head)
            return
        size = os.path.getsize(v)
        ctype = ALLOWED[os.path.splitext(v)[1].lower()]
        rng_header = self.headers.get('Range')
        rng = parse_range(rng_header, size)
        if rng == 'bad':
            self._send(416, b'', 'text/plain', head=True,
                       extra={'Content-Range': 'bytes */%d' % size})
            return
        start, end = rng if rng else (0, size - 1)
        length = end - start + 1
        STATS['video_requests'] += 1
        if start == 0 or not rng:
            log('видео: %s, Range=%s' % (os.path.basename(v), rng_header or '-'))
        self.send_response(206 if rng else 200)
        self.send_header('Content-Type', ctype)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(length))
        if rng:
            self.send_header('Content-Range', 'bytes %d-%d/%d' % (start, end, size))
        self.send_header('Cache-Control', 'no-store')
        self._cors()
        self.end_headers()
        if head:
            return
        try:
            with open(v, 'rb') as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(CHUNK, remaining))
                    if not chunk:           # файл стал короче: рвём соединение
                        self.close_connection = True
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
                    STATS['bytes'] += len(chunk)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, TimeoutError):
            self.close_connection = True      # телефон перемотал или закрыл — это нормально

    def _home(self, head):
        v, err = current_video(CONFIG)
        ips = local_ips()
        rows = ''.join('<li><code>http://%s:%d/</code></li>' % (ip, PORT) for ip in ips) or '<li>не удалось определить IP (команда ipconfig)</li>'
        if err:
            state = '<p style="color:#c00"><b>Видео недоступно:</b> %s</p>' % escape(err)
        else:
            state = '<p style="color:#070"><b>Видео готово:</b> %s (%.1f МБ)</p>' % (
                escape(v), os.path.getsize(v) / 1048576.0)
        html = ('<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta http-equiv="refresh" content="5">'
                '<title>Сервер видео Dubbing Prompter</title></head><body style="font-family:sans-serif;max-width:720px;margin:24px auto;padding:0 12px">'
                '<h2>Сервер видео Dubbing Prompter работает</h2>%s'
                '<p>Адреса этого компьютера в сети:</p><ul>%s</ul>'
                '<p>Настройки: <code>%s</code><br>Запросов: %d, видео-запросов: %d, передано: %.1f МБ, работает: %d с</p>'
                '<p>Если телефон не подключается: разрешите <b>python.exe</b> в брандмауэре Windows для частной сети '
                'и проверьте, что телефон и ПК в одной Wi-Fi сети.</p></body></html>') % (
            state, rows, escape(CONFIG), STATS['requests'], STATS['video_requests'],
            STATS['bytes'] / 1048576.0, int(time.time() - STATS['start']))
        self._send(200, html.encode('utf-8'), 'text/html; charset=utf-8', head)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # на Windows SO_REUSEADDR позволяет запустить вторую копию на том же порту — не хотим
    allow_reuse_address = (os.name != 'nt')
    request_queue_size = 32


def default_config():
    """Файл настроек: рядом с server.py (его пишет Prompter), иначе в папке ресурсов REAPER."""
    here = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'prompter_server.json')
    cands = [here]
    if os.name == 'nt':
        cands.append(os.path.join(os.environ.get('APPDATA', '.'), 'REAPER', 'prompter_server.json'))
    found = [c for c in cands if os.path.isfile(c)]
    if not found:
        return here
    return max(found, key=os.path.getmtime)   # берём самый свежий (его последним записал Prompter)


def main():
    global CONFIG, PORT
    try:   # консоль Windows принимает Unicode напрямую; не ломаем вывод на нестандартных кодировках
        sys.stdout.reconfigure(errors='replace')
    except Exception:
        pass
    ap = argparse.ArgumentParser(description='Сервер видео для Dubbing Prompter')
    ap.add_argument('--port', type=int, default=8765, help='порт (по умолчанию 8765)')
    ap.add_argument('--config', default=default_config(), help='файл настроек, который пишет Prompter')
    args = ap.parse_args()
    CONFIG, PORT = args.config, args.port
    try:
        srv = Server(('0.0.0.0', PORT), Handler)
    except OSError as e:
        print('ОШИБКА: не удалось занять порт %d: %s' % (PORT, e))
        print('Возможно, сервер уже запущен (закройте другое окно сервера) или порт занят другой программой.')
        sys.exit(2)
    print('=' * 60)
    print(' Сервер видео Dubbing Prompter запущен, порт %d' % PORT)
    print(' Адреса для телефона:')
    ips = local_ips()
    for ip in ips:
        print('   http://%s:%d/' % (ip, PORT))
    if not ips:
        print('   (IP не определён, выполните ipconfig)')
    print(' Настройки Prompter: ' + CONFIG)
    v, err = current_video(CONFIG)
    print(' Видео: ' + (v if v else 'пока нет — %s' % err))
    print(' Остановить: Ctrl+C или закрыть окно.')
    print('=' * 60, flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\nОстановлено.')
    finally:
        srv.server_close()


if __name__ == '__main__':
    main()
