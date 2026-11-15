import Foundation

/// Array-backed generic binary min-heap priority queue (`ContiguousArray` avoids NSArray bridging and pointer chasing).
/// Complexity: `push` O(log N), `popMin` O(log N), `peek` O(1).
public struct BinaryHeapPriorityQueue<Element> {
    private var storage = ContiguousArray<Element>()
    private let areInIncreasingOrder: (Element, Element) -> Bool

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    public init(sort areInIncreasingOrder: @escaping (Element, Element) -> Bool) {
        self.areInIncreasingOrder = areInIncreasingOrder
    }

    public func peek() -> Element? {
        storage.first
    }

    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        storage.reserveCapacity(minimumCapacity)
    }

    public mutating func push(_ element: Element) {
        storage.append(element)
        siftUp(from: storage.count - 1)
    }

    @discardableResult
    public mutating func popMin() -> Element? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 {
            return storage.removeLast()
        }
        let minElement = storage[0]
        storage[0] = storage.removeLast()
        siftDown(from: 0)
        return minElement
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) >> 1
            if areInIncreasingOrder(storage[child], storage[parent]) {
                storage.swapAt(child, parent)
                child = parent
            } else {
                break
            }
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        let total = storage.count
        while true {
            let left = (parent << 1) + 1
            if left >= total { break }
            let right = left + 1
            var smallest = left
            if right < total && areInIncreasingOrder(storage[right], storage[left]) {
                smallest = right
            }
            if areInIncreasingOrder(storage[smallest], storage[parent]) {
                storage.swapAt(parent, smallest)
                parent = smallest
            } else {
                break
            }
        }
    }
}
