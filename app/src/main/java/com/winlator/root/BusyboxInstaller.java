package com.winlator.root;

import android.content.Context;
import android.os.Build;
import android.util.Log;

import com.winlator.core.FileUtils;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.Locale;

/** Downloads and keeps the chroot helper script and NDK busybox binary. */
public abstract class BusyboxInstaller {
    private static final String TAG = "RootWinlator";
    private static final String BASE_URL =
        "https://github.com/YasserNull/ndk-box-kitchen/releases/download/build%231/";
    private static final String HELPER_NAME = "root_winlator_chroot.sh";
    private static final String HELPER_URL =
        "https://gist.githubusercontent.com/YasserNull/19a375d3689084d4fa506a5ec6fbc4f5/raw/318e782e1fd0e70f03a22e0a1b227786f2074129/root_winlator_chroot.sh";
    private static final String HELPER_SHA256 =
        "71dcb86f2f231d84c76fa58e7630df0bb015102a6f35e38edf3b97406c4ffa80";

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
        return new File(getBinDir(context), HELPER_NAME);
    }

    public static boolean ensure(Context context) {
        File binDir = getBinDir(context);
        File busybox = getBusyboxFile(context);

        if (!ensureHelper(context)) return false;

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

    public static synchronized boolean ensureHelper(Context context) {
        File binDir = getBinDir(context);
        File helper = getHelperScript(context);

        if (helper.isFile() && helper.length() > 0 && HELPER_SHA256.equalsIgnoreCase(sha256(helper))) {
            Log.i(TAG, "chroot helper: already present bytes="+helper.length());
            FileUtils.chmod(helper, 0755);
            return true;
        }

        File tmp = new File(binDir, HELPER_NAME+".download");
        if (tmp.exists()) tmp.delete();

        Log.i(TAG, "chroot helper: downloading url="+HELPER_URL);
        if (!download(HELPER_URL, tmp) || !HELPER_SHA256.equalsIgnoreCase(sha256(tmp))) {
            tmp.delete();
            Log.e(TAG, "chroot helper: download or sha256 verification failed");
            return false;
        }

        if (helper.exists()) helper.delete();
        if (!tmp.renameTo(helper)) {
            FileUtils.copy(tmp, helper);
            tmp.delete();
        }

        FileUtils.chmod(helper, 0755);
        Log.i(TAG, "chroot helper: installed bytes="+helper.length());
        return true;
    }

    private static String sha256(File file) {
        try (InputStream in = new FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = in.read(buffer)) != -1) digest.update(buffer, 0, count);
            byte[] hash = digest.digest();
            StringBuilder builder = new StringBuilder(hash.length * 2);
            for (byte value : hash) builder.append(String.format(Locale.ENGLISH, "%02x", value & 0xff));
            return builder.toString();
        }
        catch (Throwable e) {
            Log.e(TAG, "chroot helper: sha256 failed for "+file, e);
            return "";
        }
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
            Log.e(TAG, "download failed: "+url, e);
            return false;
        }
        finally {
            if (connection != null) connection.disconnect();
        }
    }
}
