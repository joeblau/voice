import Accelerate

/// Small vector helpers on `[Float]`, backed by vDSP.
enum VectorMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        vDSP.dot(a, b)
    }

    static func norm(_ a: [Float]) -> Float {
        dot(a, a).squareRoot()
    }

    /// `a` scaled to unit length, or `a` unchanged when it is all zeros.
    static func normalized(_ a: [Float]) -> [Float] {
        let length = norm(a)
        guard length > 0, length.isFinite else { return a }
        return vDSP.divide(a, length)
    }

    /// Cosine similarity, or 0 when either vector is all zeros.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let denominator = Double(norm(a)) * Double(norm(b))
        guard denominator > 0, denominator.isFinite else { return 0 }
        return min(1, max(-1, Double(dot(a, b)) / denominator))
    }

    /// The element-wise sum of `vectors`, all of length `dimension`.
    static func sum<C: Collection>(_ vectors: C, dimension: Int) -> [Float] where C.Element == [Float] {
        var total = [Float](repeating: 0, count: dimension)
        guard dimension > 0 else { return total }
        total.withUnsafeMutableBufferPointer { total in
            guard let output = total.baseAddress else { return }
            for vector in vectors {
                precondition(vector.count == dimension, "Vector length \(vector.count) != \(dimension)")
                vector.withUnsafeBufferPointer { vector in
                    guard let input = vector.baseAddress else { return }
                    vDSP_vadd(output, 1, input, 1, output, 1, vDSP_Length(dimension))
                }
            }
        }
        return total
    }
}
