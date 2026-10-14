#!/usr/bin/env python3
"""Writes the dashxml corpus cases too large or too repetitive to commit.

  big_segmentlist.mpd  2.8 MB: three Representations x 8000 SegmentURLs plus a
                       6000-entry SegmentTimeline. Size, entity-bearing
                       attributes in bulk, and the tree's linked lists at scale.
  deep_ok.mpd          a 240-level chain beside the AdaptationSet: inside the
                       256-level limit libxml2 enforces without XML_PARSE_HUGE.
  fail_deep.mpd        300 levels: past it. Both builds must refuse it.

Usage: gen-corpus.py <output-dir>
"""
import os
import sys

HEAD = '<?xml version="1.0" encoding="UTF-8"?>'
NS = 'xmlns="urn:mpeg:dash:schema:mpd:2011"'
REP = ('<AdaptationSet mimeType="video/mp4"><Representation id="deep" bandwidth="1">'
       '<BaseURL>deep.mp4</BaseURL></Representation></AdaptationSet>')


def big_segmentlist():
    reps = []
    for r in range(3):
        segs = ''.join(
            '<SegmentURL media="seg/%d/chunk_%06d.m4s?sig=abcdef0123456789&amp;e=1760000000"'
            ' mediaRange="%d-%d"/>\n' % (r, i, i * 1000, i * 1000 + 999)
            for i in range(8000))
        reps.append(
            '<Representation id="r%d" bandwidth="%d" codecs="avc1.64001f">'
            '<BaseURL>https://big.example/v%d/</BaseURL>'
            '<SegmentList timescale="1000" duration="4000"><Initialization sourceURL="init.mp4"/>\n'
            '%s</SegmentList></Representation>' % (r, (r + 1) * 500000, r, segs))
    timeline = ''.join('<S t="%d" d="4000"/>' % (i * 4000) for i in range(6000))
    return (HEAD + '<MPD %s type="static" mediaPresentationDuration="PT8H"><Period>'
            '<AdaptationSet mimeType="video/mp4">%s</AdaptationSet>'
            '<AdaptationSet mimeType="audio/mp4"><SegmentTemplate timescale="1000" media="a_$Time$.m4s">'
            '<SegmentTimeline>%s</SegmentTimeline></SegmentTemplate>'
            '<Representation id="a" bandwidth="128000"/></AdaptationSet></Period></MPD>\n'
            % (NS, ''.join(reps), timeline))


def nested(levels, sibling):
    return (HEAD + '<MPD %s type="static"><Period>%s%s%s</Period></MPD>\n'
            % (NS, '<x>' * levels, '</x>' * levels, sibling))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    cases = {
        'big_segmentlist.mpd': big_segmentlist(),
        # The chain is a sibling of the AdaptationSet, so a parse that gets
        # through the depth still yields the Representation.
        'deep_ok.mpd': nested(240, REP),
        'fail_deep.mpd': nested(300, ''),
    }
    for name, text in cases.items():
        with open(os.path.join(out, name), 'w', encoding='utf-8') as f:
            f.write(text)


if __name__ == '__main__':
    main()
