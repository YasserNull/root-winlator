package com.winlator.root;

import com.topjohnwu.superuser.Shell;

/**
 * Thin, app-wide wrapper around libsu.
 *
 * <p>Root is required by the chroot backend, but this class never executes a
 * root command during development or when the device is not rooted. Every
 * caller must handle {@link #requestRoot()} returning {@code false}.</p>
 */
public abstract class RootShell {
    private static boolean initialized;

    private RootShell() {}

    public static synchronized void init() {
        if (initialized) return;
        initialized = true;
        Shell.setDefaultBuilder(Shell.Builder.create()
            .setFlags(Shell.FLAG_REDIRECT_STDERR)
            .setTimeout(30));
    }

    /** Blocks until su returns. Must not be called from the main thread. */
    public static boolean requestRoot() {
        init();
        try {
            Shell shell = Shell.getShell();
            return shell != null && shell.isRoot();
        }
        catch (Throwable e) {
            return false;
        }
    }

    public static Shell.Result exec(String command) {
        init();
        return Shell.cmd(command).exec();
    }

    public static void execAsync(String command) {
        try {
            init();
            Shell.cmd(command).submit();
        }
        catch (Throwable ignored) {}
    }
}
