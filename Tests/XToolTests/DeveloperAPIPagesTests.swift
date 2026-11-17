import Testing
@testable import XKit

private actor PageCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

@Test func cancelledPaginationThrowsInsteadOfReturningPartialResults() async {
    let counter = PageCounter()
    let (requestStarted, signal) = AsyncStream<Void>.makeStream()
    let (proceedStream, proceed) = AsyncStream<Void>.makeStream()
    let task = Task<Bool, Never> {
        let pages = DeveloperAPIPages {
            let page = await counter.next()
            if page == 1 {
                signal.yield()
                for await _ in proceedStream { break }
            }
            return page
        } next: { page in
            page == 1 ? "https://example.test/items?cursor=second&limit=1" : nil
        }
        do {
            for try await _ in pages {}
            return false
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
    }
    for await _ in requestStarted { break }
    task.cancel()
    proceed.yield()
    #expect(await task.value)
}
