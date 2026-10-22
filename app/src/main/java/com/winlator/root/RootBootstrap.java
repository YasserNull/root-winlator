package com.winlator.root;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.winlator.core.Callback;

import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/** One-shot bootstrap: obtain root, install busybox binary, prepare the chroot path. */
public abstract class RootBootstrap {
    private static final String TAG = "RootWinlator";
    private static volatile boolean ready;
    private static volatile boolean chrootSupported;
    private static volatile boolean attempted;
    private static final AtomicBoolean running = new AtomicBoolean();

    private RootBootstrap() {}

    public static boolean isReady() {
        return ready;
    }

    public static boolean isAttempted() {
        return attempted;
    }

    /**
     * Blocks a background thread until bootstrap finishes. Returns false when
     * the attempt failed or the timeout expired.
     */
    public static boolean awaitReady(long timeoutMs) {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            if (ready) return true;
            if (attempted && !running.get()) return false;
            try {
                Thread.sleep(100);
            }
            catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                return ready;
            }
        }
        return ready;
    }

    /**
     * False when this kernel/SELinux refuses unshare. Chroot is then disabled
     * instead of falling back to a plain chroot that a guest could escape via
     * /proc/<app>/root.
     */
    public static boolean isChrootSupported() {
        return chrootSupported;
    }

    public static int uid() {
        return android.os.Process.myUid();
    }

    public static int gid() {
        try {
            return android.system.Os.getgid();
        }
        catch (Throwable e) {
            return android.os.Process.myUid();
        }
    }

    /**
     * Heavy work runs off the main thread. The callback is always delivered on
     * the main thread. No root command is executed before su actually grants
     * root.
     */
    public static void prepare(final Context context, final Callback<Boolean> callback) {
        final Context appContext = context.getApplicationContext();
        Executors.newSingleThreadExecutor().execute(() -> {
            if (!running.compareAndSet(false, true)) {
                if (ready) post(callback, true);
                return;
            }

            boolean success = false;
            attempted = true;
            long started = System.currentTimeMillis();
            Log.i(TAG, "bootstrap: start");
            try {
                Log.i(TAG, "bootstrap: requesting su");
                if (RootShell.requestRoot()) {
                    Log.i(TAG, "bootstrap: su granted");
                    boolean bb = BusyboxInstaller.ensure(appContext);
                    Log.i(TAG, "bootstrap: busybox ensure="+bb);
                    if (bb) {
                        boolean prepared = ChrootManager.prepare(appContext);
                        Log.i(TAG, "bootstrap: chroot prepare="+prepared);
                        success = prepared;
                    }
                    if (success) {
                        chrootSupported = ChrootManager.checkUnshare(appContext);
                        Log.i(TAG, "bootstrap: unshare supported="+chrootSupported);
                        if (!chrootSupported) Log.w(TAG, "unshare unavailable; chroot disabled");
                    }
                }
                else {
                    Log.w(TAG, "Root permission was not granted");
                }
            }
            catch (Throwable e) {
                Log.e(TAG, "Root bootstrap failed", e);
            }
            finally {
                ready = success;
                running.set(false);
                Log.i(TAG, "bootstrap: done success="+success+" chrootSupported="+chrootSupported+
                    " elapsedMs="+(System.currentTimeMillis()-started));
            }
            post(callback, success);
        });
    }

    private static void post(final Callback<Boolean> callback, final boolean value) {
        if (callback == null) return;
        new Handler(Looper.getMainLooper()).post(() -> callback.call(value));
    }
}
