package com.winlator.root;

import android.content.Context;
import android.os.Build;
import android.util.Log;

import com.winlator.core.FileUtils;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Locale;

/** Downloads and keeps the NDK busybox binary used by the chroot helper. */
public abstract class BusyboxInstaller {
    private static final String TAG = "RootWinlator";
    private static final String BASE_URL =
        "https://github.com/YasserNull/ndk-box-kitchen/releases/download/build%231/";

    private BusyboxInstaller() {}

    public static File getBinDir(Context context) {
        File dir = new File(context.getFilesDir(), "bin");
        if (!dir.isDirectory()) dir.mkdirs();
        return dir;
    }

    public static File getBusyboxFile(Context context) {
        return new File(getBinDir(context), "busybox");
    }

    public static File getHelperScript(Context context) {
        return new File(getBinDir(context), "chroot-run.sh");
    }

    public static boolean ensure(Context context) {
        File binDir = getBinDir(context);
        File busybox = getBusyboxFile(context);
        File helper = getHelperScript(context);

        try {
            Log.i(TAG, "busybox: extracting helper -> "+helper);
            FileUtils.copy(context, "chroot/chroot-run.sh", helper);
            FileUtils.chmod(helper, 0755);
        }
        catch (Throwable e) {
            Log.e(TAG, "Cannot extract chroot helper", e);
            return false;
        }

        if (!busybox.isFile() || busybox.length() == 0) {
            String abi = supportedAbi();
            String url = BASE_URL + "libbusybox-" + abi + ".so";
            Log.i(TAG, "busybox: downloading abi="+abi+" url="+url);
            File tmp = new File(binDir, "busybox.download");
            if (tmp.exists()) tmp.delete();
            if (!download(url, tmp)) {
                tmp.delete();
                Log.e(TAG, "Cannot download busybox binary for " + abi);
                return false;
            }
            if (!tmp.renameTo(busybox)) {
                FileUtils.copy(tmp, busybox);
                tmp.delete();
            }
            Log.i(TAG, "busybox: downloaded bytes="+busybox.length());
        }
        else Log.i(TAG, "busybox: already present bytes="+busybox.length());

        FileUtils.chmod(busybox, 0755);
        boolean ok = busybox.isFile() && busybox.length() > 0;
        Log.i(TAG, "busybox: ensure result="+ok);
        return ok;
    }

    private static String supportedAbi() {
        String[] abis = Build.SUPPORTED_ABIS;
        for (String abi : abis) {
            switch (abi.toLowerCase(Locale.ENGLISH)) {
                case "arm64-v8a":
                    return "arm64-v8a";
                case "armeabi-v7a":
                case "armeabi":
                    return "armeabi-v7a";
                case "x86_64":
                    return "x86_64";
                case "x86":
                    return "x86";
            }
        }
        return "arm64-v8a";
    }

    private static boolean download(String url, File destination) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection)new URL(url).openConnection();
            connection.setConnectTimeout(20000);
            connection.setReadTimeout(60000);
            connection.setInstanceFollowRedirects(true);
            connection.setRequestProperty("User-Agent", "root-winlator");
            if (connection.getResponseCode() != HttpURLConnection.HTTP_OK) return false;

            try (InputStream in = new BufferedInputStream(connection.getInputStream());
                 OutputStream out = new FileOutputStream(destination)) {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while ((count = in.read(buffer)) != -1) out.write(buffer, 0, count);
            }
            return destination.length() > 0;
        }
        catch (Throwable e) {
            Log.e(TAG, "busybox binary download failed", e);
            return false;
        }
        finally {
            if (connection != null) connection.disconnect();
        }
    }
}
