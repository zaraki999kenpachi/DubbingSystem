package ru.dubbing.prompter;

import android.app.Activity;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;

/** Отдельный класс, чтобы API 33+ не загружался на старых версиях Android. */
final class Api33 {
    private Api33() {}

    static void registerBack(Activity a, Runnable action) {
        OnBackInvokedCallback cb = action::run;
        a.getOnBackInvokedDispatcher()
                .registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, cb);
    }
}
