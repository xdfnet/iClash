import Foundation
import os.log

/// Mihomo External Controller API 客户端
///
/// 通过 HTTP 调用 `/path:port` 上的 Mihomo 控制接口：
/// - `GET /proxies`       列出所有代理组及节点
/// - `PUT /proxies/{g}`   切换代理组中选中的节点
/// - `GET /version`       查询内核版本
///
/// 设计为 stateless：所有方法都接受一个 `apiBaseURL`，
/// 便于在测试中注入 fake server。
@MainActor
struct MihomoAPIClient {
    let apiBaseURL: URL
    private let logger = Logger(subsystem: "com.iclash.macos", category: "MihomoAPIClient")

    init(apiBaseURL: URL) {
        self.apiBaseURL = apiBaseURL
    }

    // MARK: - GET /proxies

    /// 获取所有代理组及节点信息（最多重试 3 次）
    func fetchProxies(retryCount: Int = 3) async throws -> [String: ProxyInfo] {
        let url = apiBaseURL.appendingPathComponent("proxies")
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        var lastError: Error?
        for attempt in 0..<retryCount {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let response = try JSONDecoder().decode(ProxiesResponse.self, from: data)
                return response.proxies
            } catch {
                lastError = error
                if attempt < retryCount - 1 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError ?? MihomoError.apiNotAvailable
    }

    // MARK: - PUT /proxies/{group}

    /// 选择代理组中要使用的节点
    func selectProxy(name: String, in group: String) async throws {
        let encodedGroup = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? group
        let url = apiBaseURL.appendingPathComponent("proxies/\(encodedGroup)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            throw MihomoError.apiSelectFailed
        }
    }

    // MARK: - GET /version

    /// 获取内核版本（最多重试 2 次）；返回 nil 表示失败
    func fetchKernelVersion(retryCount: Int = 2) async -> String? {
        let url = apiBaseURL.appendingPathComponent("version")

        for attempt in 0..<retryCount {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = json["version"] as? String {
                    return version
                }
            } catch {
                if attempt == retryCount - 1 {
                    logger.error("Failed to fetch kernel version: \(error.localizedDescription, privacy: .public)")
                }
            }

            if attempt < retryCount - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return nil
    }
}

// MARK: - 响应模型

struct ProxyInfo: Codable {
    let name: String
    let type: String
    let all: [String]?
    let now: String?
}

struct ProxiesResponse: Codable {
    let proxies: [String: ProxyInfo]
}