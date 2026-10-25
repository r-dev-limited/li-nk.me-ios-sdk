import Foundation

internal protocol RequestTask: AnyObject {
  func resume()
  func cancel()
}

extension URLSessionDataTask: RequestTask {}

internal typealias NetworkCompletion = @Sendable (Data?, URLResponse?, Error?) -> Void
internal typealias RequestTaskFactory = (URLRequest, @escaping NetworkCompletion) -> RequestTask

/// Owns complete-operation deadlines independently of URLSession's idle timeout.
/// Entries are removed under the lock before cancelling or calling user code.
internal final class RequestScope: @unchecked Sendable {
  private struct Entry {
    let task: RequestTask
    let deadline: DispatchWorkItem
    let completion: NetworkCompletion
  }

  private let lock = NSLock()
  private var pending: [UUID: Entry] = [:]
  private let makeTask: RequestTaskFactory

  init(urlSession: URLSession, makeTask: RequestTaskFactory? = nil) {
    self.makeTask = makeTask ?? { request, completion in
      urlSession.dataTask(with: request, completionHandler: completion)
    }
  }

  func start(_ request: URLRequest, completion: @escaping NetworkCompletion) {
    let id = UUID()
    let task = makeTask(request) { [weak self] data, response, error in
      self?.finish(id, data: data, response: response, error: error, cancelTask: false)
    }
    let deadline = DispatchWorkItem { [weak self] in
      self?.finish(id, data: nil, response: nil, error: URLError(.timedOut), cancelTask: true)
    }
    lock.lock()
    pending[id] = Entry(task: task, deadline: deadline, completion: completion)
    lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + request.timeoutInterval, execute: deadline)
    task.resume()
  }

  func cancelAll() {
    lock.lock()
    let entries = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    for entry in entries {
      entry.deadline.cancel()
      entry.task.cancel()
      entry.completion(nil, nil, URLError(.cancelled))
    }
  }

  private func finish(_ id: UUID, data: Data?, response: URLResponse?, error: Error?, cancelTask: Bool) {
    lock.lock()
    let entry = pending.removeValue(forKey: id)
    lock.unlock()
    guard let entry else { return }
    entry.deadline.cancel()
    if cancelTask { entry.task.cancel() }
    entry.completion(data, response, error)
  }

  deinit { cancelAll() }
}

/// The callback is accessed on the SDK's serial delivery queue. This box lets
/// public callback signatures remain source-compatible with Swift 5 consumers.
internal final class CallbackBox<Value>: @unchecked Sendable {
  let call: (Value) -> Void
  init(_ call: @escaping (Value) -> Void) { self.call = call }
}
