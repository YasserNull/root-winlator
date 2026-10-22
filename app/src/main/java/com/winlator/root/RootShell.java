package com.winlator.root;

import android.util.Log;

import com.topjohnwu.superuser.Shell;

/**
 * Thin, app-wide wrapper around libsu.
 *
 * <p>Root is required by the chroot backend, but this class never executes a
 * root command during development or when the device is not rooted. Every
 * caller must handle {@link #requestRoot()} returning {@code false}.</p>
 */
public abstract class RootShell {
    private static final String TAG = "RootWinlator";
    private static boolean initialized;

    private RootShell() {}

    public static synchronized void init() {
        if (initialized) return;
        initialized = true;
        Shell.enableVerboseLogging = true;
        Shell.setDefaultBuilder(Shell.Builder.create()
            .setFlags(Shell.FLAG_REDIRECT_STDERR)
            .setTimeout(30));
        Log.i(TAG, "libsu: initialized verboseLogging=true uid="+android.os.Process.myUid());
    }

    /** Blocks until su returns. Must not be called from the main thread. */
    public static boolean requestRoot() {
        init();
        try {
            Boolean granted = Shell.isAppGrantedRoot();
            Log.i(TAG, "libsu: isAppGrantedRoot="+granted);
            Shell shell = Shell.getShell();
            int status = shell != null ? shell.getStatus() : -1;
            boolean alive = shell != null && shell.isAlive();
            boolean root = shell != null && shell.isRoot();
            Log.i(TAG, "libsu: getShell="+(shell != null ? shell.getClass().getName() : "null")+
                " status="+status+" alive="+alive+" isRoot="+root);
            return root;
        }
        catch (Throwable e) {
            Log.e(TAG, "libsu: requestRoot failed", e);
            return false;
        }
    }

    public static Shell.Result exec(String command) {
        init();
        Log.i(TAG, "libsu: exec command="+command);
        Shell.Result result = Shell.cmd(command).exec();
        Log.i(TAG, "libsu: exec code="+result.getCode()+" success="+result.isSuccess()+
            " out="+result.getOut()+" err="+result.getErr());
        return result;
    }

    public static void execAsync(String command) {
        try {
            init();
            Log.i(TAG, "libsu: execAsync command="+command);
            Shell.cmd(command).submit(result -> Log.i(TAG, "libsu: execAsync code="+result.getCode()+
                " success="+result.isSuccess()+" out="+result.getOut()+" err="+result.getErr()));
        }
        catch (Throwable e) {
            Log.e(TAG, "libsu: execAsync failed", e);
        }
    }
}
