import Foundation
import OpenCodeKit
import SwaTex
import SwaTexRender

struct ResponseFormulaKey: Hashable, Sendable {
  let source: String
  let display: Bool
  init(_ formula: MarkdownFormula) {
    source = formula.source
    display = formula.display
  }
}

struct ResponseFormulaRaster: Sendable {
  let png: Data
  let scale: Double
}

actor ResponseFormulas {
  static let shared = ResponseFormulas()
  private let cache = NSCache<NSString, Raster>()
  private let layouts = FormulaCache(capacity: 256)
  private let fontSize = 19.36

  init() { cache.totalCostLimit = 16 * 1024 * 1024 }

  func measure(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    func runs(_ values: [MarkdownRun]) -> [MarkdownRun] {
      values.map { run in
        guard var formula = run.formula else { return run }
        var result = run
        guard permitted(formula.source),
          let list = try? SwaTexEngine.displayList(for: formula.source,
            style: formula.display ? .display : .text, cache: layouts), !list.truncated else {
          result.text = formula.source
          result.offsets = Array(repeating: run.offsets.first ?? nil, count: formula.source.utf16.count)
          result.formula = nil
          return result
        }
        let metrics = DisplayListRenderer.metrics(for: list, options: RenderOptions(fontSize: fontSize, padding: 0))
        guard metrics.width.isFinite, metrics.height.isFinite, metrics.width <= 4096, metrics.height <= 2048,
          metrics.width * metrics.height * 9 <= 8_000_000 else {
          result.text = formula.source
          result.offsets = Array(repeating: run.offsets.first ?? nil, count: formula.source.utf16.count)
          result.formula = nil
          return result
        }
        formula.metrics = .init(width: metrics.width, height: metrics.height, baseline: metrics.baseline)
        result.formula = formula
        return result
      }
    }
    return blocks.map { block in
      var result = block
      result.runs = runs(block.runs)
      result.children = measure(block.children)
      if var table = block.table {
        table.rows = table.rows.map { $0.map(runs) }
        result.table = table
      }
      return result
    }
  }

  func rasters(_ blocks: [MarkdownBlock], theme: String, color: ThemeColor, scale: Double) -> [ResponseFormulaKey: ResponseFormulaRaster] {
    let scale = min(scale, 3)
    var result: [ResponseFormulaKey: ResponseFormulaRaster] = [:]
    func visit(_ blocks: [MarkdownBlock]) {
      for block in blocks {
        let runs = block.runs + (block.table?.rows.flatMap { $0.flatMap { $0 } } ?? [])
        for run in runs {
          guard let formula = run.formula, let metrics = formula.metrics else { continue }
          let key = ResponseFormulaKey(formula)
          guard result[key] == nil else { continue }
          let identity = "\(theme):\(scale):\(formula.display):\(formula.source)" as NSString
          if let value = cache.object(forKey: identity) { result[key] = value.value; continue }
          guard metrics.width * metrics.height * scale * scale <= 8_000_000,
            let list = try? SwaTexEngine.displayList(for: formula.source,
              style: formula.display ? .display : .text,
              color: SwaTex.Color(r: Float(color.red), g: Float(color.green), b: Float(color.blue), a: Float(color.opacity)), cache: layouts),
            !list.truncated,
            let png = SwaTexRender.ImageRenderer.png(for: list,
              options: RenderOptions(fontSize: fontSize, padding: 0), displayScale: scale) else { continue }
          let value = ResponseFormulaRaster(png: png, scale: scale)
          cache.setObject(Raster(value: value), forKey: identity, cost: Int(metrics.width * metrics.height * scale * scale * 4))
          result[key] = value
        }
        visit(block.children)
      }
    }
    visit(blocks)
    return result
  }

  private func permitted(_ source: String) -> Bool {
    guard source.utf16.count <= 8000 else { return false }
    // These counts allocate columns during layout, before bitmap limits apply.
    let expression = try! NSRegularExpression(pattern: #"\\begin\{(?:alignat|alignedat)\}\{(\d+)\}"#)
    return expression.matches(in: source, range: NSRange(location: 0, length: source.utf16.count)).allSatisfy {
      Int((source as NSString).substring(with: $0.range(at: 1))).map { $0 <= 32 } ?? false
    }
  }

  private final class Raster {
    let value: ResponseFormulaRaster
    init(value: ResponseFormulaRaster) { self.value = value }
  }
}
