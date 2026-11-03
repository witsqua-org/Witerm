import Foundation

/// The replayed streams, bundled from .build/spikes/streams by the project.
enum Streams {
    static func url(_ name: String) -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "streams") else {
            fatalError("missing stream \(name); run scripts/gen-streams.py")
        }
        return url
    }

    static func bytes(_ name: String) -> [UInt8] {
        [UInt8](try! Data(contentsOf: url(name)))
    }

    /// Display frames from a *.frames file ([u32 LE length][bytes] records).
    static func frames(_ name: String) -> [[UInt8]] {
        let data = bytes(name)
        var frames: [[UInt8]] = []
        var i = 0
        while i + 4 <= data.count {
            let len = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
            i += 4
            frames.append(Array(data[i..<(i + len)]))
            i += len
        }
        return frames
    }

    /// All of a stream's bytes, frames concatenated.
    static func flat(_ name: String) -> [UInt8] {
        name.hasSuffix(".frames") ? frames(name).flatMap { $0 } : bytes(name)
    }
}

extension Array where Element == UInt8 {
    /// Calls body with consecutive chunks of at most `size` bytes.
    func chunks(_ size: Int, _ body: (UnsafeRawBufferPointer) -> Void) {
        withUnsafeBytes { all in
            var i = 0
            while i < all.count {
                let n = Swift.min(size, all.count - i)
                body(UnsafeRawBufferPointer(rebasing: all[i..<(i + n)]))
                i += n
            }
        }
    }
}
