package android.util;

import org.kxml2.io.KXmlParser;
import org.xmlpull.v1.XmlPullParser;

/** Stub: on Android, Xml.newPullParser() is libcore's KXmlParser. */
public final class Xml {
    public static XmlPullParser newPullParser() {
        return new KXmlParser();
    }
}
