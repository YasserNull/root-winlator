package com.winlator.root;

import android.content.Context;
import android.os.Process;
import android.util.Base64;
import android.util.Log;

import com.winlator.core.Callback;
import com.winlator.core.EnvVars;
import com.winlator.core.ProcessHelper;
import com.topjohnwu.superuser.Shell;

import java.io.File;
import java.nio.charset.StandardCharsets;

/**
 * Owns the host-side chroot lifecycle.
 *
 * <p>The distribution is always placed at {@link #ROOTFS_PATH}. The Java side
 * only prepares files and asks the shell helper to mount/run/unmount; it never
 * calls libc directly and never assumes the process is running as root.</p>
 */
public abstract class ChrootManager {
    private static final String TAG = "RootWinlator";

    public static final String ROOTFS_PATH = "/data/local/tmp/root-winlator";

    private ChrootManager() {}

    public static File getRootDir() {
        return new File(ROOTFS_PATH);
    }

    private static File helper(Context context) {
        return BusyboxInstaller.getHelperScript(context);
    }

    private static File busybox(Context context) {
        return BusyboxInstaller.getBusyboxFile(context);
    }

    /** App-private, not bind-mounted into the chroot. Guest cannot see it. */
    private static String stateDir(Context context) {
        return BusyboxInstaller.getBinDir(context).getAbsolutePath();
    }

    /** Migrate the old app-private rootfs and clean stale mounts from a crash. */
    public static boolean prepare(Context context) {
        String oldRoot = new File(context.getFilesDir(), "rootfs").getAbsolutePath();
        String oldImage = new File(context.getFilesDir(), "imagefs").getAbsolutePath();
        String appFiles = context.getFilesDir().getAbsolutePath();
        String script = helper(context).getAbsolutePath();
        String bb = busybox(context).getAbsolutePath();
        String cmd = "mkdir -p " + quote(ROOTFS_PATH) + "; " +
            "if [ ! -f " + quote(ROOTFS_PATH + "/.winlator/.rfs_version") + " ]; then " +
            "if [ -d " + quote(oldRoot) + " ]; then rm -rf " + quote(ROOTFS_PATH) +
            "; mv " + quote(oldRoot) + " " + quote(ROOTFS_PATH) + "; " +
            "elif [ -d " + quote(oldImage) + " ]; then rm -rf " + quote(ROOTFS_PATH) +
            "; mv " + quote(oldImage) + " " + quote(ROOTFS_PATH) + "; fi; fi; " +
            "chown " + RootBootstrap.uid() + ":" + RootBootstrap.gid() + " " +
            quote(ROOTFS_PATH) + "; chmod 0771 " + quote(ROOTFS_PATH) + "; " +
            // /data/local/tmp is shell_data_file. Give the rootfs the app's
            // SELinux context so the Java installer can still write into it.
            "CTX=$(/system/bin/ls -Zd " + quote(appFiles) + " 2>/dev/null | " +
            quote(bb) + " awk '{print $1}'); " +
            "[ -n \"$CTX\" ] && /system/bin/chcon \"$CTX\" " + quote(ROOTFS_PATH) +
            " 2>/dev/null; " +
            "/system/bin/sh " + quote(script) + " stop " + quote(ROOTFS_PATH) + " " + quote(bb) + " " +
            RootBootstrap.uid() + " " + RootBootstrap.gid() + " " + quote(stateDir(context));

        try {
            Log.i(TAG, "prepare: rootfs="+ROOTFS_PATH+" oldRoot="+oldRoot+" oldImage="+oldImage);
            Shell.Result result = RootShell.exec(cmd);
            Log.i(TAG, "prepare: success="+result.isSuccess()+" out="+result.getOut()+
                " err="+result.getErr());
            if (!result.isSuccess()) {
                Log.w(TAG, "prepare: " + result.getErr());
                return false;
            }
            return true;
        }
        catch (Throwable e) {
            Log.e(TAG, "prepare failed", e);
            return false;
        }
    }

    /** Called once during bootstrap. Plain chroot is not an acceptable fallback. */
    public static boolean checkUnshare(Context context) {
        String bb = busybox(context).getAbsolutePath();
        try {
            boolean ok = RootShell.exec(quote(bb) + " unshare -m -p -f " + quote(bb) +
                " true 2>/dev/null").isSuccess();
            Log.i(TAG, "checkUnshare: supported="+ok);
            return ok;
        }
        catch (Throwable e) {
            Log.w(TAG, "unshare check failed", e);
            return false;
        }
    }

    public static boolean mount(Context context, boolean fixSuid, boolean bindRam,
                                boolean bindAndroid) {
        String cmd = "/system/bin/sh " + quote(helper(context).getAbsolutePath()) + " mount " +
            quote(ROOTFS_PATH) + " " + quote(busybox(context).getAbsolutePath()) + " " +
            (fixSuid ? "1" : "0") + " " + (bindRam ? "1" : "0") + " " +
            (bindAndroid ? "1" : "0") + " " + RootBootstrap.uid() + " " +
            RootBootstrap.gid() + " " + quote(stateDir(context));
        try {
            Log.i(TAG, "mount: start flags fixSuid="+fixSuid+" bindRam="+bindRam+
                " bindAndroid="+bindAndroid);
            Shell.Result result = RootShell.exec(cmd);
            Log.i(TAG, "mount: success="+result.isSuccess()+" out="+result.getOut()+
                " err="+result.getErr());
            if (!result.isSuccess()) {
                Log.e(TAG, "mount: " + result.getErr());
                return false;
            }
            return true;
        }
        catch (Throwable e) {
            Log.e(TAG, "mount failed", e);
            return false;
        }
    }

    /**
     * Starts su -> helper -> chroot. The returned pid belongs to the su
     * launcher; actual guest pids are discovered from /proc by ProcessHelper.
     */
    public static int launch(Context context, File rootDir, String command,
                             EnvVars envVars, boolean fixSuid, boolean bindRam,
                             boolean bindAndroid, Callback<Integer> terminationCallback) {
        // Env and command are passed as base64 arguments, never as app-writable
        // files. A chrooted guest can therefore not inject root shell code.
        String envScript = buildEnvironment(envVars, rootDir.getAbsolutePath());
        String envB64 = Base64.encodeToString(envScript.getBytes(StandardCharsets.UTF_8),
            Base64.NO_WRAP);
        // The rootfs has no shell: the helper exec's argv directly via
        // `eval "set -- $CMD"`. Split like the normal (non-chroot) launcher
        // and single-quote every word so backslashes (C:\windows) survive.
        StringBuilder argv = new StringBuilder();
        for (String arg : ProcessHelper.splitCommand(command)) {
            if (argv.length() > 0) argv.append(' ');
            argv.append(shellQuote(arg));
        }
        String cmdB64 = Base64.encodeToString((argv + "\n").getBytes(StandardCharsets.UTF_8),
            Base64.NO_WRAP);

        String script = helper(context).getAbsolutePath();
        String bb = busybox(context).getAbsolutePath();
        String helperCmd = "/system/bin/sh " + quote(script) + " run " + quote(ROOTFS_PATH) + " " +
            quote(bb) + " " + Process.myPid() + " " + envB64 + " " + cmdB64 + " " +
            RootBootstrap.uid() + " " + RootBootstrap.gid() + " " +
            quote(stateDir(context)) + " " + (fixSuid ? "1" : "0") + " " +
            (bindRam ? "1" : "0") + " " + (bindAndroid ? "1" : "0");

        String su = new File("/system/bin/su").exists() ? "/system/bin/su" : "su";
        Log.i(TAG, "launch: flags fixSuid="+fixSuid+" bindRam="+bindRam+
            " bindAndroid="+bindAndroid+" envCount="+envVars.size()+
            " cmdLen="+command.length()+" su="+su);
        File suCwd = context.getFilesDir();
        if (suCwd == null || !suCwd.isDirectory()) suCwd = new File("/");
        int pid = ProcessHelper.exec(new String[]{su, "-c", helperCmd}, new EnvVars(), suCwd,
            (status) -> {
                Log.i(TAG, "launch: guest wrapper exited status="+status);
                if (terminationCallback != null) terminationCallback.call(status);
            }, true);
        Log.i(TAG, "launch: su wrapper pid="+pid);
        return pid;
    }

    public static void stop(Context context) {
        String cmd = "/system/bin/sh " + quote(helper(context).getAbsolutePath()) + " stop " +
            quote(ROOTFS_PATH) + " " + quote(busybox(context).getAbsolutePath()) + " " +
            RootBootstrap.uid() + " " + RootBootstrap.gid() + " " +
            quote(stateDir(context));
        Log.i(TAG, "stop: requested");
        RootShell.execAsync(cmd);
    }

    private static String buildEnvironment(EnvVars envVars, String rootDir) {
        StringBuilder sb = new StringBuilder();
        for (String name : envVars) {
            // The environment script is evaluated by the root shell. Never let
            // a crafted variable name (e.g. from an imported container) inject
            // shell syntax.
            if (name == null || !name.matches("[A-Za-z_][A-Za-z0-9_]*")) continue;
            String value = envVars.get(name);
            if (value == null) continue;
            // Paths are host absolute paths. Inside the chroot the rootfs is /,
            // so strip the host prefix. This also fixes PATH with several entries.
            value = value.replace(rootDir, "");
            if (value.isEmpty()) value = "/";
            sb.append("export ").append(name).append('=').append(shellQuote(value)).append('\n');
        }
        return sb.toString();
    }

    private static String shellQuote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }

    private static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }
}
