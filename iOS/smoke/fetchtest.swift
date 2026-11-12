// 用与 App 完全相同的 URLSession 栈(含信任所有证书)测试目标 URL 连通性
// 用法: ./fetchtest <url> [--browser]
import Foundation

let urlStr = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "https://example.com/"
let useBrowserHeaders = CommandLine.arguments.contains("--browser")

final class TrustAll: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

var finished = false
var request = URLRequest(url: URL(string: urlStr)!)
request.timeoutInterval = 15
if useBrowserHeaders {
    request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
    request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
}
let session = URLSession(configuration: .ephemeral, delegate: TrustAll(), delegateQueue: nil)
// completion 在 URLSession 自有队列；finished 标志位主线程 RunLoop 轮询（冒烟工具的良性竞争）
session.dataTask(with: request) { data, response, error in
    if let error {
        print("RESULT: FAIL ua=\(useBrowserHeaders ? "browser" : "default") \(error)")
    } else {
        let http = response as? HTTPURLResponse
        print("RESULT: OK status=\(http?.statusCode ?? -1) bytes=\(data?.count ?? 0) ua=\(useBrowserHeaders ? "browser" : "default")")
    }
    finished = true
}.resume()

let deadline = Date().addingTimeInterval(40)
while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
if !finished { print("RESULT: TIMEOUT") }
