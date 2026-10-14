import com.solarized.firedown.ffmpegutils.FFmpegXml;

import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.Paths;

/**
 * Hands a manifest to the REAL FFmpegXml.parse() the way fdxml.c does over
 * JNI — a direct ByteBuffer — and writes its answer for dash_dump.c.
 * Exit 3 = parse() returned null (the manifest is refused).
 */
public final class FdxmlCli {
    public static void main(String[] args) throws Exception {
        byte[] in = Files.readAllBytes(Paths.get(args[0]));
        ByteBuffer buffer = ByteBuffer.allocateDirect(in.length);
        buffer.put(in).flip();
        byte[] out = FFmpegXml.parse(buffer);
        if (out == null) {
            System.exit(3);
        }
        Files.write(Paths.get(args[1]), out);
    }
}
