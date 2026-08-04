// Copyright © 2026 Saleem Abdulrasool <compnerd@compnerd.org>. All rights reserved.
// SPDX-License-Identifier: BSD-3-Clause

/// The `EXPLAIN` plan renderer — a stable pretty-printer for the optimised
/// physical `Plan`.
///
/// `EXPLAIN <query>` builds the plan through the ordinary compile → pushdown →
/// decorrelate → optimise pipeline (`Catalog.plan(of:)`) and renders it here,
/// one operator per line, laid out as an indented tree with box-drawing
/// connectors (`├─`/`└─`/`│`) — the same tree idiom the CLI's table output
/// draws its frames in. Each line names an operator and annotates the
/// optimiser-relevant fields: a scan's referenced ordinals and seek range, a
/// join's kind and seek key, an elided-or-kept DISTINCT, a decorrelated apply's
/// correlation, and so on. The render is a pure function of the `Plan` — no
/// addresses, no set/dictionary iteration order — so a test may pin it.
///
/// It renders the plan node faithfully as the optimiser shaped it: a `.join` is
/// an index-nested-loop equi-join in shape, and the render says so, but it does
/// not simulate the executor's runtime hash-vs-seek choice (which depends on
/// the inner column's live seekability). The physical node is the ground truth.

extension Plan {
  /// The optimised plan rendered as an indented operator tree — one line per
  /// node, the root unindented and each child hung under its parent with a
  /// box-drawing connector. This is what `EXPLAIN` yields, one text row per
  /// line.
  internal func render() -> Array<String> {
    var lines = Array<String>()
    render(prefix: "", leading: "", into: &lines)
    return lines
  }

  /// Appends this node's label line (prefixed by `leading`) and then each
  /// child's subtree, hung under a `├─`/`└─` connector with the running
  /// `prefix` extended by `│  ` (a middle child's descendants) or three spaces
  /// (the last child's), so the tree's spine draws correctly at every depth.
  private func render(prefix: String, leading: String,
                      into lines: inout Array<String>) {
    lines.append(leading + label)
    let nodes = children
    for index in nodes.indices {
      let last = index == nodes.count - 1
      let branch = prefix + (last ? "└─ " : "├─ ")
      let onward = prefix + (last ? "   " : "│  ")
      nodes[index].render(prefix: onward, leading: branch, into: &lines)
    }
  }

  /// This operator's sub-plans, in draw order — the children the tree hangs
  /// under it. A `join`'s inner relation is named and re-materialised per outer
  /// record rather than being a sub-plan, so it is annotated in the `label`,
  /// not listed here; likewise an `apply`'s correlated body (looked up by key).
  private var children: Array<Plan> {
    switch self {
    case .single, .values, .empty, .scan:
      []
    case let .derived(_, plan, _, _):
      [plan]
    case let .select(_, source), let .project(_, source),
         let .sort(_, source), let .distinct(source),
         let .aggregate(_, _, source), let .window(_, source),
         let .limit(_, _, source), let .join(source, _, _, _, _, _, _),
         let .apply(source, _, _, _, _, _):
      [source]
    case let .product(left, right), let .outer(left, right, _, _),
         let .semijoin(left, right, _, _), let .setop(_, left, right, _, _, _):
      [left, right]
    }
  }

  /// The single-line label for this operator — its kind plus the
  /// optimiser-relevant fields the render annotates.
  private var label: String {
    switch self {
    case .single:
      return "single"
    case let .values(rows, types):
      return "values  rows \(rows.count)  columns \(types.count)"
    case let .empty(slots):
      return "empty  slots \(slots)"
    case let .scan(name, ordinals, seek):
      return "scan \(escaped(name))  reads \(list(ordinals))"
          + rendered(seek: seek)
    case let .derived(name, _, ordinals, seek):
      return "derived \(escaped(name))  reads \(list(ordinals))"
          + rendered(seek: seek)
    case let .select(filter, _):
      return "select  \(filter.rendered)"
    case let .project(terms, _):
      return "project [" + terms.map(\.rendered).joined(separator: ", ") + "]"
    case let .sort(keys, _):
      let rendered = keys.map {
        "\($0.term.rendered) \($0.ascending ? "ASC" : "DESC")"
      }
      return "sort  " + rendered.joined(separator: ", ")
    case .product:
      return "product (nested loop)"
    case let .join(_, name, ordinals, base, column, keys, filter):
      var label = "join (index nested loop)  inner \(escaped(name))"
      label += "  on slot \(keys.left) = slot \(keys.right)"
      label += "  seek column \(column)  base \(base)  reads \(list(ordinals))"
      if let filter { label += "  inner filter \(filter.rendered)" }
      return label
    case let .outer(_, _, on, kind):
      return "outer \(kind.keyword)  on \(on.rendered)"
    case let .semijoin(_, _, on, anti):
      return "semijoin\(anti ? " (anti)" : "")  on \(on.rendered)"
    case let .apply(_, _, correlation, ordinals, on, kind):
      var label = "apply \(kind.keyword)  correlation \(rendered(correlation))"
      label += "  reads \(list(ordinals))  on \(on.rendered)"
      return label
    case let .setop(kind, _, _, all, _, _):
      return kind.keyword + (all ? " all" : "")
    case .distinct:
      return "distinct"
    case let .aggregate(keys, aggregates, _):
      let keyed = keys.map(\.rendered).joined(separator: ", ")
      let folds = aggregates.map(\.rendered).joined(separator: ", ")
      return "aggregate  keys [\(keyed)]  aggregates [\(folds)]"
    case let .window(windowings, _):
      let rendered = windowings.map(\.rendered).joined(separator: ", ")
      return "window [\(rendered)]"
    case let .limit(count, offset, _):
      let cap = count.map { "\($0)" } ?? "all"
      return "limit  count \(cap)" + (offset > 0 ? "  offset \(offset)" : "")
    }
  }
}

// MARK: - Field rendering

/// A comma-separated `[a, b, c]` spelling of an ordinal list, for a scan's
/// referenced ordinals and a join/apply's taken ones.
private func list(_ ordinals: Array<Int>) -> String {
  "[" + ordinals.map { "\($0)" }.joined(separator: ", ") + "]"
}

/// The `  seek lower..<upper` annotation of a planned row-range seek, or the
/// empty string when the scan reads the whole relation (`nil`).
private func rendered(seek: Range<Int>?) -> String {
  guard let seek else { return "" }
  return "  seek \(seek.lowerBound)..<\(seek.upperBound)"
}

/// A correlated node's parameter bindings rendered `[:name ← source, …]`, the
/// names sorted so the line is stable regardless of the map's iteration order.
private func rendered(_ correlation: Correlation) -> String {
  let bindings = correlation.keys.sorted().map { name in
    "\(param(name)) ← \(rendered(correlation[name]!))"
  }
  return "[" + bindings.joined(separator: ", ") + "]"
}

/// A correlation source's spelling — an outer cell, a merged column, or a
/// threaded binding.
private func rendered(_ source: Source) -> String {
  switch source {
  case let .slot(slot):
    return "slot \(slot)"
  case let .coalesce(slots, _):
    return "coalesce(" + slots.map { "slot \($0)" }.joined(separator: ", ")
        + ")"
  case .bound:
    return "bound"
  }
}

extension Comparison {
  /// This comparison operator's SQL symbol, for a rendered predicate.
  fileprivate var symbol: String {
    switch self {
    case .equal: "="
    case .unequal: "<>"
    case .lt: "<"
    case .gt: ">"
    case .leq: "<="
    case .geq: ">="
    }
  }
}

extension Arithmetic {
  /// This arithmetic operator's SQL symbol, for a rendered term.
  fileprivate var symbol: String {
    switch self {
    case .add: "+"
    case .subtract: "-"
    case .multiply: "*"
    case .divide: "/"
    case .concatenate: "||"
    }
  }
}

extension Join.Kind {
  /// This join kind's ISO keyword, for a rendered `outer`/`apply` node.
  fileprivate var keyword: String {
    switch self {
    case .inner: "INNER"
    case .left: "LEFT"
    case .right: "RIGHT"
    case .full: "FULL"
    }
  }
}

extension SetOperation {
  /// This set operator's ISO keyword, for a rendered `setop` node.
  fileprivate var keyword: String {
    switch self {
    case .union: "union"
    case .intersect: "intersect"
    case .except: "except"
    }
  }
}

extension Quantifier {
  /// This quantifier's ISO keyword, for a rendered quantified predicate.
  fileprivate var keyword: String {
    switch self {
    case .any: "ANY"
    case .all: "ALL"
    }
  }
}

extension Truth {
  /// This truth value's ISO keyword, for a rendered `IS <truth>` predicate.
  fileprivate var keyword: String {
    switch self {
    case .true: "TRUE"
    case .false: "FALSE"
    case .unknown: "UNKNOWN"
    }
  }
}

// MARK: - Value rendering

extension Value {
  /// This constant's plan-tree spelling — a NULL as `NULL`, text single-quoted
  /// with its control characters and quotes escaped, a blob as a lowercase-hex
  /// `x'…'` literal, the rest their bare description.
  fileprivate var literal: String {
    switch self {
    case .null: "NULL"
    case let .integer(integer): "\(integer)"
    case let .double(double): "\(double)"
    case let .text(text): "'\(escaped(text, quote: true))'"
    case let .boolean(boolean): boolean ? "TRUE" : "FALSE"
    case let .blob(bytes):
      "x'" + bytes.map(Value.hex).joined() + "'"
    }
  }

  /// A byte's two lowercase-hex nibbles, high nibble first — the per-byte
  /// spelling a rendered blob literal joins.
  private static func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]])
  }
}

// MARK: - Term rendering

extension Term {
  /// This lowered scalar term's plan-tree spelling — a slot read, a constant, a
  /// correlated parameter, or a compound expression over such.
  fileprivate var rendered: String {
    switch self {
    case let .slot(slot):
      return "slot \(slot)"
    case let .parameter(name):
      return param(name)
    case let .constant(value):
      return value.literal
    case let .apply(name, arguments):
      return "\(escaped(name))(" + arguments.map(\.rendered)
          .joined(separator: ", ") + ")"
    case let .binary(op, lhs, rhs):
      return "(\(lhs.rendered) \(op.symbol) \(rhs.rendered))"
    case let .case(branches, otherwise, _):
      let arms = branches.map { "WHEN \($0.0.rendered) THEN \($0.1.rendered)" }
      let tail = otherwise.map { " ELSE \($0.rendered)" } ?? ""
      return "CASE " + arms.joined(separator: " ") + tail + " END"
    case let .cast(term, type):
      return "CAST(\(term.rendered) AS \(type.domain))"
    case let .coalesce(elements, _):
      return "COALESCE(" + elements.map(\.rendered).joined(separator: ", ")
          + ")"
    case let .nullif(lhs, rhs):
      return "NULLIF(\(lhs.rendered), \(rhs.rendered))"
    case let .subquery(_, correlation, _):
      return correlation.isEmpty ? "(subquery)" : "(correlated subquery)"
    case let .grouping(_, bits):
      return "GROUPING(\(bits))"
    }
  }
}

// MARK: - Filter rendering

extension Filter.Operand {
  /// This `LIKE`/`BETWEEN` operand's spelling — a lowered term or a run-time
  /// parameter.
  fileprivate var rendered: String {
    switch self {
    case let .term(term): term.rendered
    case let .parameter(name): param(name)
    }
  }
}

extension Filter {
  /// This lowered predicate's plan-tree spelling — a comparison, a connective,
  /// or one of the ISO predicate forms, rendered in slot space.
  fileprivate var rendered: String {
    switch self {
    case let .compare(lhs, op, rhs):
      return "\(lhs.rendered) \(op.symbol) \(rhs.rendered)"
    case let .bound(lhs, op, name):
      return "\(lhs.rendered) \(op.symbol) \(param(name))"
    case let .match(left, right):
      return "slot \(left) = slot \(right)"
    case let .null(term, negated):
      return "\(term.rendered) IS \(negated ? "NOT " : "")NULL"
    case let .membership(operand, values, negated):
      return "\(operand.rendered)\(negated ? " NOT" : "") IN ("
          + values.map(\.rendered).joined(separator: ", ") + ")"
    case let .comparison(lhs, op, rhs):
      return "\(row(lhs)) \(op.symbol) \(row(rhs))"
    case let .memberships(lhs, rows, negated):
      let elements = rows.map(row).joined(separator: ", ")
      return "\(row(lhs))\(negated ? " NOT" : "") IN (\(elements))"
    case let .like(operand, pattern, escape, negated):
      let tail = escape.map { " ESCAPE \($0.rendered)" } ?? ""
      return "\(operand.rendered)\(negated ? " NOT" : "") LIKE "
          + pattern.rendered + tail
    case let .between(test, lower, upper, negated):
      return "\(test.rendered)\(negated ? " NOT" : "") BETWEEN "
          + "\(lower.rendered) AND \(upper.rendered)"
    case let .distinct(lhs, rhs, negated):
      return "\(lhs.rendered) IS \(negated ? "NOT " : "")DISTINCT FROM "
          + rhs.rendered
    case let .exists(_, correlation, negated):
      return "\(negated ? "NOT " : "")EXISTS \(subquery(correlation))"
    case let .within(lhs, _, correlation, negated):
      return "\(row(lhs))\(negated ? " NOT" : "") IN \(subquery(correlation))"
    case let .quantified(lhs, op, quantifier, _, correlation):
      return "\(row(lhs)) \(op.symbol) \(quantifier.keyword) "
          + subquery(correlation)
    case let .truth(filter, value, negated):
      return "\(filter.rendered) IS \(negated ? "NOT " : "")\(value.keyword)"
    case let .and(lhs, rhs):
      return "(\(lhs.rendered) AND \(rhs.rendered))"
    case let .or(lhs, rhs):
      return "(\(lhs.rendered) OR \(rhs.rendered))"
    case let .not(operand):
      return "NOT \(operand.rendered)"
    case let .incomparable(inner):
      return "incomparable(\(inner.rendered))"
    }
  }
}

/// A row-value operand `(a, b, c)` rendered from its component terms — the
/// parenthesised form an ISO row comparison/membership prints.
private func row(_ terms: Array<Term>) -> String {
  "(" + terms.map(\.rendered).joined(separator: ", ") + ")"
}

/// A parameter name rendered `:name` with exactly one leading colon, whether or
/// not the stored name already carries it — a user `:p` is stored bare while a
/// synthetic correlated name (`:__correlated_0_0`) keeps its colon, so this
/// normalises both to one spelling.
private func param(_ name: String) -> String {
  ":" + escaped(String(name.drop(while: { $0 == ":" })))
}

/// `text` with its backslash and control characters backslash-escaped — and,
/// under `quote`, its single quotes too — so a rendered value or user-provided
/// identifier is a single operator line with unambiguous quoting. A delimited
/// identifier or a text constant may hold a newline or a quote verbatim; left
/// raw it would split the line and corrupt the single-line box the shell frames
/// it in. `quote` escapes the wrapping single quotes a text literal adds; a
/// bare identifier (a relation, routine, or parameter name) is rendered
/// unquoted, so it escapes control characters alone.
private func escaped(_ text: String, quote: Bool = false) -> String {
  var spelled = ""
  for scalar in text.unicodeScalars {
    switch scalar {
    case "\\": spelled += "\\\\"
    case "'" where quote: spelled += "\\'"
    case "\n": spelled += "\\n"
    case "\r": spelled += "\\r"
    case "\t": spelled += "\\t"
    case let control where control.value < 0x20:
      spelled += "\\u{\(String(control.value, radix: 16))}"
    default: spelled.unicodeScalars.append(scalar)
    }
  }
  return spelled
}

/// A subquery operand's spelling — marked correlated when its `correlation`
/// binds an outer cell (it re-runs per outer row), plain when uncorrelated.
private func subquery(_ correlation: Correlation) -> String {
  correlation.isEmpty ? "(subquery)" : "(correlated subquery)"
}

// MARK: - Aggregate and window rendering

extension Aggregation {
  /// This lowered aggregate's plan-tree spelling — `FUNCTION(argument)`, with
  /// `DISTINCT` and a `FILTER (WHERE …)` when present, and `*` for `COUNT(*)`.
  fileprivate var rendered: String {
    let inner = "\(distinct ? "DISTINCT " : "")\(argument?.rendered ?? "*")"
    let gate = filter.map { " FILTER (WHERE \($0.rendered))" } ?? ""
    return "\(function.keyword)(\(inner))\(gate)"
  }
}

extension Windowing {
  /// This lowered window's plan-tree spelling — `FUNCTION OVER (PARTITION BY …
  /// ORDER BY … <frame>)`, each clause omitted when empty. An explicit frame is
  /// rendered so windows folding different row sets — `ROWS BETWEEN 1 PRECEDING
  /// AND CURRENT ROW` vs `5 PRECEDING` — are distinct plan lines.
  fileprivate var rendered: String {
    var over = Array<String>()
    if !partition.isEmpty {
      over.append("PARTITION BY "
          + partition.map(\.rendered).joined(separator: ", "))
    }
    if !order.isEmpty {
      let keys = order.map {
        "\($0.term.rendered) \($0.ascending ? "ASC" : "DESC")"
      }
      over.append("ORDER BY " + keys.joined(separator: ", "))
    }
    if let frame { over.append(frame.rendered) }
    return "\(function.rendered) OVER (\(over.joined(separator: " ")))"
  }
}

extension Frame {
  /// This window frame's plan-tree spelling — `<unit> BETWEEN <start> AND
  /// <end>`, so an explicit frame's unit and bounds distinguish the row set the
  /// window folds.
  fileprivate var rendered: String {
    "\(unit.keyword) BETWEEN \(start.rendered) AND \(end.rendered)"
  }
}

extension Frame.Unit {
  /// This frame unit's ISO keyword.
  fileprivate var keyword: String {
    switch self {
    case .rows: "ROWS"
    case .range: "RANGE"
    case .groups: "GROUPS"
    }
  }
}

extension Frame.Bound {
  /// This frame bound's plan-tree spelling.
  fileprivate var rendered: String {
    switch self {
    case .unboundedPreceding: "UNBOUNDED PRECEDING"
    case let .preceding(rows): "\(rows) PRECEDING"
    case .currentRow: "CURRENT ROW"
    case let .following(rows): "\(rows) FOLLOWING"
    case .unboundedFollowing: "UNBOUNDED FOLLOWING"
    }
  }
}

extension Windowing.Function {
  /// This lowered window function's plan-tree spelling — its ISO name and any
  /// lowered operands (an aggregate window rendered as its aggregation).
  fileprivate var rendered: String {
    switch self {
    case .rowNumber: return "ROW_NUMBER()"
    case .rank: return "RANK()"
    case .denseRank: return "DENSE_RANK()"
    case let .aggregate(aggregation): return aggregation.rendered
    case let .lead(value, offset, fallback):
      let tail = fallback.map { ", \($0.rendered)" } ?? ""
      return "LEAD(\(value.rendered), \(offset)\(tail))"
    case let .lag(value, offset, fallback):
      let tail = fallback.map { ", \($0.rendered)" } ?? ""
      return "LAG(\(value.rendered), \(offset)\(tail))"
    case let .firstValue(value): return "FIRST_VALUE(\(value.rendered))"
    case let .lastValue(value): return "LAST_VALUE(\(value.rendered))"
    case let .nthValue(value, n): return "NTH_VALUE(\(value.rendered), \(n))"
    case let .ntile(n): return "NTILE(\(n))"
    case .percentRank: return "PERCENT_RANK()"
    case .cumeDist: return "CUME_DIST()"
    }
  }
}

// MARK: - Explain

extension Catalog where Self: ~Escapable {
  /// Renders `query`'s optimised physical plan as one text row per plan-tree
  /// line — the rows the `EXPLAIN <query>` statement yields.
  ///
  /// It builds the plan through `plan(of:)` — the same compile → pushdown →
  /// decorrelate → optimise pipeline a run drives — and renders it, without
  /// executing the query. The result is a single-column relation of `.text`
  /// cells (`columns(of:)` names the column `plan`), so the CLI frames it as a
  /// one-column table and an `expect(…)`/`run(_ statement:)` test reads the
  /// plan lines back as ordinary rows.
  internal borrowing func explain(_ query: Query, _ context: Context)
      throws(SQLError) -> Array<Array<Value>> {
    try plan(of: query, context).render().map { [.text($0)] }
  }
}
