package com.github.catvod.crawler;

import android.util.Log;

public class SpiderDebug {
    private static final String TAG = "GoMovieSpider";

    public static void log(Throwable e) {
        if (e != null) {
            Log.w(TAG, e);
        }
    }

    public static void log(String msg) {
        if (msg != null) {
            Log.d(TAG, msg);
        }
    }
}
