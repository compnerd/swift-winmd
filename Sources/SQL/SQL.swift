// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

extension Statement {
  /// Parses SQL text into a `Statement`.
  ///
  /// The text's UTF-8 bytes are streamed through the lexer and parsed by
  /// recursive descent into a SQL abstract syntax tree. The dialect is minimal:
  ///
  /// ```sql
  /// SELECT <* | column (, column)*> FROM <table>
  ///   [WHERE <predicate>] [ORDER BY <column> [ASC|DESC]]
  ///   (UNION [ALL] SELECT …)*
  /// ```
  ///
  /// The resulting AST is generic: it names a relation and its columns as
  /// strings and carries no knowledge of how they resolve. Binding the names to
  /// a data source is the consumer's responsibility.
  ///
  /// - Parameter text: the SQL query to parse.
  /// - Throws: `SQLError` on a lexical or syntactic fault, carrying the source
  ///   location of the offending span where one is known.
  public init(parsing text: String) throws(SQLError) {
    // The lexer scans bytes by value over the input's contiguous UTF-8 storage,
    // exposed as a `Span<UInt8>`. The span is borrowed only for the duration of
    // the lex-and-parse; the resulting `Statement` is fully escapable, so
    // nothing tied to the borrow survives.
    let bytes = text.utf8Span.span
    var parser = try Parser(Lexer(bytes))
    self = try parser.parse()
  }
}
