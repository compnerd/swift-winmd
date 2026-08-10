// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

// The statement stream a shell's `for`-in drives — the input's `;`-separated
// SQL statements yielded one at a time from a line source.

/// The statement stream a `for`-in drives — the input's statements yielded one
/// at a time from a line source.
///
/// `Statements` is a `Sequence` over a *line source* (a `() -> String?` — either
/// `readLine` for stdin, or the lines of a `String` for the argument and
/// `.read`). Its iterator reads lines and yields either a whole `.`-prefixed
/// meta statement, or a SQL statement accumulated across lines until a
/// terminating `;`. This is the `;`-accumulation the old loop did, lifted into
/// an ordinary iterator so the driving is a literal `for`-in.
///
/// A `.`-meta whose single-quoted string is still OPEN (an unbalanced `'`) is
/// the one exception to the whole-line rule: it accumulates subsequent RAW lines
/// verbatim until the quote closes, yielding the whole block as one statement —
/// the shape `.template <name> '<body>'` takes, a Mustache template written
/// inline as a multiline single-quoted literal. Because the body is
/// quote-delimited DATA, `.end`, `;`, and `{{…}}` inside it are verbatim, never
/// a terminator; only a literal `'` needs doubling. The open-quote test is the
/// same quote scan `terminator(in:)` runs (`''` an escaped quote), shared as
/// `open(in:)`. A multiline meta is recognised only for the `spellings` a host
/// registers (the winmd shell's `.template`); with none, every `.`-meta yields
/// whole.
public struct Statements: Sequence {
  /// The line source — `readLine` for stdin, or a closure over a string's
  /// lines for the argument and `.read`.
  private let lines: () -> String?

  /// A hook called before each line is read, told whether a statement is
  /// pending (a mid-accumulation, unterminated statement). The interactive
  /// shell passes one to emit its primary/continuation prompt; the argument and
  /// `.read` paths leave it `nil` so a batch never prompts.
  private let prompt: ((Bool) -> Void)?

  /// The `.`-meta spellings whose single-quoted body accumulates across lines
  /// (the winmd shell's `.template`). A meta not in this set yields whole even
  /// with an unbalanced `'`, so an apostrophe in an argument is data.
  private let multiline: Set<String>

  /// Streams statements read line-by-line from `lines`, optionally calling
  /// `prompt` before each read with whether a statement is pending — the
  /// interactive shell's prompt hook. `multiline` names the `.`-meta spellings
  /// that carry a line-spanning single-quoted body.
  public init(reading lines: @escaping () -> String?,
              prompt: ((Bool) -> Void)? = nil,
              multiline: Set<String> = []) {
    self.lines = lines
    self.prompt = prompt
    self.multiline = multiline
  }

  /// Streams the statements of `text`, reading its lines. A batch never
  /// prompts, so it has no prompt hook.
  public init(of text: String, multiline: Set<String> = []) {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map(String.init)
                    .makeIterator()
    self.lines = { lines.next() }
    prompt = nil
    self.multiline = multiline
  }

  public func makeIterator() -> Iterator {
    Iterator(lines, prompt, multiline)
  }

  /// The statement iterator — the `;`-accumulator over the line source.
  public struct Iterator: IteratorProtocol {
    /// The line source the iterator pulls from.
    private let lines: () -> String?

    /// The prompt hook, called before each read with whether a statement is
    /// pending; `nil` for a batch, which never prompts.
    private let prompt: ((Bool) -> Void)?

    /// The `.`-meta spellings whose single-quoted body spans lines.
    private let multiline: Set<String>

    /// The SQL accumulated across lines, not yet closed by a `;`.
    private var pending: String

    internal init(_ lines: @escaping () -> String?,
                  _ prompt: ((Bool) -> Void)?, _ multiline: Set<String>) {
      self.lines = lines
      self.prompt = prompt
      self.multiline = multiline
      pending = ""
    }

    /// The next statement, or `nil` at end of input.
    ///
    /// A `.`-meta line (when no statement is pending) yields whole — unless its
    /// spelling is a `multiline` one whose single-quoted string is still OPEN
    /// (an unbalanced `'`), in which case it begins a multiline meta whose
    /// subsequent RAW lines accumulate verbatim (joined with `\n`, no
    /// `;`-splitting, no per-line `.`-meta handling) until the quote closes, and
    /// the whole block yields as ONE statement; the inline `.template <name>
    /// '<body>'` command is that shape, so `.end`, `;`, and `{{…}}` inside the
    /// body are data, never a terminator. Otherwise lines accumulate until a `;`
    /// closes a statement, which yields; a trailing unterminated statement (or
    /// an unterminated multiline meta) yields at end of input — the closing `;`
    /// is optional, so a one-shot query or a file without a final terminator
    /// runs its last statement.
    public mutating func next() -> String? {
      while true {
        // Drain any completed statement already accumulated. A chunk that is
        // only trivia — whitespace and comments, e.g. a `-- note` between two
        // `;` — carries no statement, so skip it rather than hand the parser
        // empty input.
        if let semicolon = Iterator.terminator(in: pending) {
          let statement = String(pending[..<semicolon]).trimmed
          pending = String(pending[pending.index(after: semicolon)...])
          guard Iterator.trivial(statement) else { return statement }
          continue
        }
        // Prompt before the read (the interactive shell only): a pending,
        // unterminated statement asks for its continuation; an empty or
        // trivia-only one asks for a fresh statement. A batch's hook is `nil`,
        // so it never prompts.
        prompt?(!Iterator.trivial(pending))
        guard let line = lines() else {
          // End of input: flush a final unterminated statement (the closing
          // `;` is optional), then clear `pending` so the next call stops. A
          // trivia-only tail (a trailing or standalone `-- comment`) is nothing
          // to run, so it ends the stream rather than reaching the parser.
          let statement = pending.trimmed
          pending = ""
          return Iterator.trivial(statement) ? nil : statement
        }
        // A `.`-meta line yields whole when no statement is pending — a
        // whitespace-only or comment-only line before it is trivia, so drop it
        // rather than glue the meta line onto it (a `-- note` before `.schema`
        // must not turn the meta into SQL). A `multiline` meta alone carries a
        // single-quoted (possibly multiline) body: when ITS quote is left open,
        // keep accumulating raw lines until the quote closes, then yield the
        // whole block as one statement. Every other meta yields whole, so an
        // apostrophe in an argument — a `.read /tmp/O'Brien.sql` path — is data,
        // not an unterminated literal that would swallow the following lines.
        if Iterator.trivial(pending), line.trimmed.first == "." {
          let meta = line.trimmed
          let spelling = String(meta.prefix { !$0.isWhitespace })
          guard multiline.contains(spelling), Iterator.open(in: meta) else {
            pending = ""
            return meta
          }
          return accumulate(meta)
        }
        pending += pending.isEmpty ? line : "\n" + line
      }
    }

    /// Accumulates the multiline meta block whose single-quoted body is open,
    /// starting from `meta` (its first, trimmed line), reading RAW lines
    /// verbatim (joined with `\n`, no `;`-splitting, no per-line `.`-meta
    /// handling) until the quote closes, then yielding the whole block as one
    /// statement. End of input before the quote closes flushes what was
    /// captured — the closing `'` is as optional as a trailing `;`.
    private mutating func accumulate(_ meta: String) -> String {
      var block = meta
      while Iterator.open(in: block) {
        prompt?(true)
        guard let line = lines() else { break }
        block += "\n" + line
      }
      pending = ""
      return block
    }

    /// The index in `text` of the first `;` that terminates a statement — one
    /// outside a string literal, a delimited identifier, and a comment — or
    /// `nil` when there is none (including when `text` trails off inside an
    /// unclosed `'…'` or `"…"`). A `;` inside `'…'`, `"…"`, `--`, or `/* … */`
    /// is data, not a terminator, so the split matches what the SQL lexer
    /// scans.
    ///
    /// It runs the shared `scan`, as `open(in:)` does, so both agree on what a
    /// literal, an identifier, and a comment are.
    private static func terminator(in text: String) -> String.Index? {
      var index = text.startIndex
      var enclosure = Enclosure.none
      while index < text.endIndex {
        if Iterator.scan(text, &index, &enclosure) { continue }
        if enclosure == .none, text[index] == ";" { return index }
        index = text.index(after: index)
      }
      return nil
    }

    /// Whether `text` ends inside an unclosed single-quoted literal — a
    /// QUOTE-ONLY scan for a multiline meta's body accumulation. Unlike the SQL
    /// `terminator` scan it does NOT skip comments or track delimited
    /// identifiers: a meta line is meta-command text, not SQL, so a `--`, `/*`,
    /// or `"` in its name or body is data, and only a `'…'` (a doubled `''`
    /// escaped) opens or closes the body. `false` when every `'` is balanced, so
    /// the line stands complete.
    private static func open(in text: String) -> Bool {
      var index = text.startIndex
      var quoted = false
      while index < text.endIndex {
        let character = text[index]
        if quoted {
          if character == "'" {
            let next = text.index(after: index)
            if next < text.endIndex, text[next] == "'" {
              index = text.index(after: next)
              continue
            }
            quoted = false
          }
        } else if character == "'" {
          quoted = true
        }
        index = text.index(after: index)
      }
      return quoted
    }

    /// The literal/identifier the scan is currently inside — none, a single-
    /// quoted string, or a double-quoted delimited identifier. A comment or a
    /// `;` terminator is recognised only in `.none`; inside a string or an
    /// identifier those bytes are data, exactly as the lexer treats them.
    private enum Enclosure: Equatable { case none, string, identifier }

    /// Advances the `enclosure` state at `index` in `text`. In `.none` it
    /// enters a string on `'` or a delimited identifier on `"`, and otherwise
    /// skips a `--` or `/* … */` comment; inside a string or identifier it
    /// consumes a doubled `''`/`""` as an escaped quote (skipping both) or
    /// closes on a lone one. Returns `true` when it already advanced `index` (a
    /// skipped pair or comment — the caller must not step again), `false` when
    /// `index` still points at the character to consider. This is the SQL scan
    /// `terminator(in:)` runs; a meta's body uses the quote-only `open(in:)`
    /// instead, since `--`/`"` there are data, not SQL.
    private static func scan(_ text: String, _ index: inout String.Index,
                             _ enclosure: inout Enclosure) -> Bool {
      let character = text[index]
      switch enclosure {
      case .string:
        guard character == "'" else { return false }
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "'" {
          index = text.index(after: next)
          return true
        }
        enclosure = .none
      case .identifier:
        guard character == "\"" else { return false }
        let next = text.index(after: index)
        if next < text.endIndex, text[next] == "\"" {
          index = text.index(after: next)
          return true
        }
        enclosure = .none
      case .none:
        if character == "'" {
          enclosure = .string
        } else if character == "\"" {
          enclosure = .identifier
        } else if character == "-", let end = Iterator.simple(text, index) {
          // A `--` line comment: skip to (not past) its newline, which the
          // caller advances over as ordinary text. A `;` inside it is not a
          // terminator, matching the lexer's trivia.
          index = end
          return true
        } else if character == "/", let (end, _) = Iterator.block(text, index) {
          // A `/* … */` block comment (or an unterminated `/*` run to the end):
          // skipped whole, so a `;` inside it is not a terminator either.
          index = end
          return true
        }
      }
      return false
    }

    /// The index of the newline ending a `--` line comment begun at `index` (or
    /// `endIndex`), or `nil` when `index` begins no comment (no second `-`).
    private static func simple(_ text: String, _ index: String.Index)
        -> String.Index? {
      let second = text.index(after: index)
      guard second < text.endIndex, text[second] == "-" else { return nil }
      var cursor = text.index(after: second)
      while cursor < text.endIndex, text[cursor] != "\n" {
        cursor = text.index(after: cursor)
      }
      return cursor
    }

    /// Whether `text` carries no statement — only whitespace and comments, so
    /// it lexes to no token. Such a fragment (a trailing or standalone comment,
    /// or a blank chunk between two `;`) must not be handed to the parser,
    /// which would reject it as empty input.
    private static func trivial(_ text: String) -> Bool {
      var index = text.startIndex
      while index < text.endIndex {
        let character = text[index]
        if character == "-", let end = Iterator.simple(text, index) {
          index = end
        } else if character == "/", let comment = Iterator.block(text, index) {
          // An unterminated block comment is NOT trivia: the fragment must
          // reach the parser so the lexer reports the missing `*/`, rather than
          // being silently dropped. A closed comment is skipped.
          guard comment.closed else { return false }
          index = comment.end
        } else if character.isWhitespace {
          index = text.index(after: index)
        } else {
          return false
        }
      }
      return true
    }

    /// The end of a `/* … */` block comment begun at `index` and whether it
    /// closed: the index just past its `*/` with `closed` true, or `endIndex`
    /// with `closed` false when unterminated; `nil` when `index` begins no
    /// comment (no `*` after the `/`). The `closed` flag lets `trivial` keep an
    /// unclosed comment non-trivial so its error still reaches the parser,
    /// while `scan` consumes either way.
    private static func block(_ text: String, _ index: String.Index)
        -> (end: String.Index, closed: Bool)? {
      let second = text.index(after: index)
      guard second < text.endIndex, text[second] == "*" else { return nil }
      var cursor = text.index(after: second)
      while cursor < text.endIndex {
        if text[cursor] == "*" {
          let close = text.index(after: cursor)
          if close < text.endIndex, text[close] == "/" {
            return (text.index(after: close), true)
          }
        }
        cursor = text.index(after: cursor)
      }
      return (cursor, false)
    }
  }
}

// MARK: - Trimming

extension StringProtocol {
  /// This text with leading and trailing whitespace removed — a stdlib-only
  /// trim (no Foundation `CharacterSet`).
  package var trimmed: String {
    String(drop { $0.isWhitespace }.reversed()
               .drop { $0.isWhitespace }.reversed())
  }

  /// This statement with a single trailing `;` removed — the trailing `;` a
  /// query statement may carry is optional.
  package var statement: String {
    hasSuffix(";") ? String(dropLast()) : String(self)
  }
}
