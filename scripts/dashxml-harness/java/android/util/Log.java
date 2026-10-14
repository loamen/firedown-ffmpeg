package android.util;

/** Stub: FFmpegXml's debug lines go to stderr, which run.sh keeps per manifest. */
public final class Log {
    public static int w(String tag, String msg) {
        System.err.println("W/" + tag + ": " + msg);
        return 0;
    }

    public static int d(String tag, String msg) {
        System.err.println("D/" + tag + ": " + msg);
        return 0;
    }
}
