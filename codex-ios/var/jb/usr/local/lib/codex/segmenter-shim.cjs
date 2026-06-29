// Polyfill for broken Intl.Segmenter on iOS (Node helper only).
// Identical to the Claude Code iOS shim: V8's ICU break-iterator data is
// incomplete on the bundled iOS arm64 Node, causing crashes in any code path
// that constructs Intl.Segmenter. This provides a regex-based replacement.
// The native Codex Rust engine does NOT use this — it is only loaded via
// `node -r segmenter-shim.cjs` for the optional JS launcher / auth helper.

class SegmenterShim {
  constructor(locale = 'en', options = {}) {
    this.locale = locale;
    this.granularity = options.granularity || 'grapheme';
  }

  segment(str) {
    const granularity = this.granularity;
    const segments = [];

    if (granularity === 'word') {
      for (const match of str.matchAll(/(\s+)|(\S+)/g)) {
        segments.push({
          segment: match[0],
          index: match.index,
          isWordLike: !/^\s+$/.test(match[0]),
        });
      }
    } else if (granularity === 'sentence') {
      let lastIndex = 0;
      for (const match of str.matchAll(/[^.!?]*[.!?]+\s*/g)) {
        segments.push({ segment: match[0], index: match.index, isWordLike: true });
        lastIndex = match.index + match[0].length;
      }
      if (lastIndex < str.length) {
        segments.push({ segment: str.slice(lastIndex), index: lastIndex, isWordLike: true });
      }
    } else {
      for (let i = 0; i < str.length; i++) {
        segments.push({ segment: str[i], index: i, isWordLike: !/\s/.test(str[i]) });
      }
    }

    return {
      [Symbol.iterator]: function* () {
        for (const seg of segments) yield seg;
      },
      containing(index) {
        return segments.find((s) => s.index <= index && index < s.index + s.segment.length);
      },
    };
  }

  resolvedOptions() {
    return { locale: this.locale, granularity: this.granularity };
  }

  static supportedLocalesOf(locales) {
    return Array.isArray(locales) ? locales : [locales];
  }
}

Intl.Segmenter = SegmenterShim;
