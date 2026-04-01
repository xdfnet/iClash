import Foundation
import os.log

/// 配置文件管理器
@MainActor
final class ConfigManager {
    static let shared = ConfigManager()

    private let logger = Logger(subsystem: "com.iclash.macos", category: "ConfigManager")
    private let directSession: URLSession

    let configDirectory: URL
    let runtimeConfigFile: URL

    /// 写死的订阅地址
    let subscriptionURL = "https://boost.hobbyx.cn/d/ddb0b489d10d14ba2d8912b8d30bde03"

    /// 运行时配置文件是否存在
    var runtimeConfigFileExists: Bool {
        FileManager.default.fileExists(atPath: runtimeConfigFile.path)
    }

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
        directSession = URLSession(configuration: configuration)

        let home = FileManager.default.homeDirectoryForCurrentUser
        configDirectory = home.appendingPathComponent(".config/iclash", isDirectory: true)
        runtimeConfigFile = configDirectory.appendingPathComponent("config.yaml")
        try? createDirectoryIfNeeded()
        try? ensureGeoIPExists()
    }

    /// 确保 GeoIP 数据库存在
    private func ensureGeoIPExists() throws {
        let geoipPath = configDirectory.appendingPathComponent("Country.mmdb")
        guard !FileManager.default.fileExists(atPath: geoipPath.path) else { return }

        // 从 app bundle 复制
        if let resourcePath = Bundle.main.resourceURL {
            let bundleGeoIP = resourcePath.appendingPathComponent("Country.mmdb")
            if FileManager.default.fileExists(atPath: bundleGeoIP.path) {
                try FileManager.default.copyItem(at: bundleGeoIP, to: geoipPath)
            }
        }
    }

    /// 确保基础配置目录存在（在 init 中已自动创建）
    func ensureBaseConfigurationExists() throws {
        // 目录已在 init 中创建
    }

    /// 获取运行时配置文件路径，如果可行会先刷新远程订阅
    func prepareRuntimeConfigFile() async throws -> URL {
        do {
            try await refreshRuntimeConfig()
        } catch {
            if FileManager.default.fileExists(atPath: runtimeConfigFile.path) {
                return runtimeConfigFile
            }
            throw error
        }

        return runtimeConfigFile
    }

    /// 下载订阅并保存到 config.yaml
    func downloadAndValidateConfig(url: String) async throws -> URL {
        guard URL(string: url) != nil else {
            throw ConfigError.invalidSubscriptionURL
        }

        logger.info("Downloading subscription from \(url, privacy: .private(mask: .hash))")
        let content = try await downloadSubscriptionContent(from: url)
        try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)
        logger.info("Wrote runtime config to \(self.runtimeConfigFile.path, privacy: .public), size: \(content.count)")

        return runtimeConfigFile
    }

    /// 从订阅地址生成运行配置
    func refreshRuntimeConfig() async throws {
        logger.info("Refreshing runtime config from subscription")
        let content = try await downloadSubscriptionContent(from: subscriptionURL)
        try Data(content.utf8).write(to: runtimeConfigFile, options: .atomic)
        logger.info("Updated runtime config at \(self.runtimeConfigFile.path, privacy: .public), size: \(content.count)")
    }

    /// 下载订阅内容并验证
    private func downloadSubscriptionContent(from urlString: String) async throws -> String {
        guard let subscriptionURL = URL(string: urlString) else {
            throw ConfigError.invalidSubscriptionURL
        }

        var request = URLRequest(
            url: subscriptionURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        // 使用 Mihomo User-Agent 以获取 Base64 编码的订阅内容
        request.setValue("Mihomo/1.18.1", forHTTPHeaderField: "User-Agent")
        print("[ConfigManager] 请求头: \(request.allHTTPHeaderFields ?? [:])")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await directSession.data(for: request)
        } catch {
            logger.error("Subscription request failed: \(error.localizedDescription, privacy: .public)")
            throw ConfigError.networkError(error)
        }

        if let httpResponse = response as? HTTPURLResponse {
            logger.info("Subscription response status: \(httpResponse.statusCode), bytes: \(data.count)")
            guard (200...299).contains(httpResponse.statusCode) else {
                throw ConfigError.invalidResponse(statusCode: httpResponse.statusCode)
            }
        }

        guard !data.isEmpty else {
            throw ConfigError.emptySubscription
        }

        var content = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !content.isEmpty else {
            throw ConfigError.emptySubscription
        }

        logger.debug("Downloaded subscription text length: \(content.count), raw bytes: \(data.count)")

        if content.contains("\"error\"") && content.localizedCaseInsensitiveContains("access denied") {
            throw ConfigError.subscriptionBlocked
        }

        // 尝试 Base64 解码
        if let decodedContent = try? base64Decode(content) {
            logger.info("Subscription content was base64 encoded, decoded length: \(decodedContent.count)")
            content = decodedContent
        } else {
            logger.debug("Subscription content is not base64 or does not require decoding")
        }

        // 如果内容是 URI 列表格式（以 anytls://, ss://, vmess:// 等开头）
        // 则生成完整的配置
        if isProxyUriList(content) {
            logger.info("Detected proxy URI list, generating runtime YAML config")
            content = generateConfigFromUriList(uriList: content)
        } else {
            logger.info("Subscription content is already a config file")
        }

        return content
    }

    /// 判断内容是否为代理 URI 列表格式
    private func isProxyUriList(_ content: String) -> Bool {
        let uriPrefixes = ["anytls://", "ss://", "vmess://", "vless://", "trojan://", "shadowsocks://", "hysteria://", "hysteria2://", "tuic://", "wireguard://"]
        let lines = content.components(separatedBy: .newlines)
        // 至少有3行有效的 URI 才认为是 URI 列表
        let uriLines = lines.filter { line in
            uriPrefixes.contains { line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix($0) }
        }
        return uriLines.count >= 3
    }

    /// 从 URI 列表生成完整的配置文件
    private func generateConfigFromUriList(uriList: String) -> String {
        let lines = uriList.components(separatedBy: .newlines).filter { !$0.isEmpty }
        var proxiesYaml: [String] = []
        var proxyNames: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            if let (name, proxyYaml) = parseProxyUri(trimmed) {
                proxyNames.append(name)
                proxiesYaml.append(proxyYaml)
            }
        }

        let proxiesSection = proxiesYaml.joined(separator: "\n    ")
        let proxyNamesList = proxyNames.map { "'\($0)'" }.joined(separator: ", ")

        return """
        mixed-port: 7890
        allow-lan: true
        bind-address: '*'
        mode: rule
        log-level: info
        external-controller: '127.0.0.1:9090'
        unified-delay: true
        tcp-concurrent: true
        dns:
            enable: true
            ipv6: false
            default-nameserver: [223.5.5.5, 119.29.29.29]
            enhanced-mode: fake-ip
            fake-ip-range: 198.18.0.1/16
            use-hosts: true
            nameserver-policy: { +.google.com: 'https://dns.cloudflare.com/dns-query', +.googleapis.com: 'https://dns.cloudflare.com/dns-query', +.googleapis.cn: 'https://dns.cloudflare.com/dns-query', +.googlevideo.com: 'https://dns.cloudflare.com/dns-query', +.gstatic.com: 'https://dns.cloudflare.com/dns-query', +.youtube.com: 'https://dns.cloudflare.com/dns-query', +.youtu.be: 'https://dns.cloudflare.com/dns-query', +.facebook.com: 'https://dns.cloudflare.com/dns-query', +.twitter.com: 'https://dns.cloudflare.com/dns-query', +.x.com: 'https://dns.cloudflare.com/dns-query', +.github.com: 'https://dns.cloudflare.com/dns-query', +.githubusercontent.com: 'https://dns.cloudflare.com/dns-query', +.openai.com: 'https://dns.cloudflare.com/dns-query', +.chatgpt.com: 'https://dns.cloudflare.com/dns-query', +.anthropic.com: 'https://dns.cloudflare.com/dns-query' }
            nameserver: ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query', 'tls://dot.pub:853', 'tls://dns.alidns.com:853']
            fallback: ['https://dns.cloudflare.com/dns-query', 'https://dns.google/dns-query', 'tls://1.1.1.1:853', 'tls://8.8.8.8:853']
            fallback-filter: { geoip: true, geoip-code: CN, ipcidr: [0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4], domain: [+.google.com, +.facebook.com, +.youtube.com, +.githubusercontent.com, +.googlevideo.com, +.googleapis.cn] }
            fake-ip-filter: ['*.lan', '*.local', '*.localhost', '*.test', localhost.ptlogin2.qq.com, '+.stun.*.*', '+.stun.*.*.*', '+.stun.*.*.*.*', lens.l.google.com, '*.srv.nintendo.net', +.stun.playstation.net, 'xbox.*.*.microsoft.com', '*.*.xboxlive.com', +.msftncsi.com, +.msftconnecttest.com]
        proxies:
            \(proxiesSection)
        proxy-groups:
            - { name: BoostNet, type: select, proxies: [自动选择, 故障转移, DIRECT, \(proxyNamesList)] }
            - { name: 自动选择, type: url-test, proxies: [\(proxyNamesList)], url: 'http://www.gstatic.com/generate_204', interval: 300, tolerance: 50 }
            - { name: 故障转移, type: fallback, proxies: [\(proxyNamesList)], url: 'http://www.gstatic.com/generate_204', interval: 300 }
        rules:
            - 'DOMAIN,2.boostnetapp.top,DIRECT'
            - 'DOMAIN-KEYWORD,admarvel,REJECT'
            - 'DOMAIN-KEYWORD,admaster,REJECT'
            - 'DOMAIN-KEYWORD,adsage,REJECT'
            - 'DOMAIN-KEYWORD,adsmogo,REJECT'
            - 'DOMAIN-KEYWORD,adsrvmedia,REJECT'
            - 'DOMAIN-KEYWORD,adwords,REJECT'
            - 'DOMAIN-KEYWORD,adservice,REJECT'
            - 'DOMAIN-KEYWORD,domob,REJECT'
            - 'DOMAIN-KEYWORD,duomeng,REJECT'
            - 'DOMAIN-KEYWORD,dwtrack,REJECT'
            - 'DOMAIN-KEYWORD,guanggao,REJECT'
            - 'DOMAIN-KEYWORD,lianmeng,REJECT'
            - 'DOMAIN-KEYWORD,omgmta,REJECT'
            - 'DOMAIN-KEYWORD,openx,REJECT'
            - 'DOMAIN-KEYWORD,partnerad,REJECT'
            - 'DOMAIN-KEYWORD,supersonicads,REJECT'
            - 'DOMAIN-KEYWORD,umeng,REJECT'
            - 'DOMAIN-KEYWORD,zjtoolbar,REJECT'
            - 'DOMAIN-SUFFIX,appsflyer.com,REJECT'
            - 'DOMAIN-SUFFIX,doubleclick.net,REJECT'
            - 'DOMAIN-SUFFIX,mmstat.com,REJECT'
            - 'DOMAIN-SUFFIX,local,DIRECT'
            - 'DOMAIN-SUFFIX,localhost,DIRECT'
            - 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
            - 'IP-CIDR,17.0.0.0/8,DIRECT,no-resolve'
            - 'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve'
            - 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'
            - 'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve'
            - 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
            - 'IP-CIDR,198.18.0.0/16,DIRECT,no-resolve'
            - 'IP-CIDR,224.0.0.0/4,DIRECT,no-resolve'
            - 'IP-CIDR6,::1/128,DIRECT,no-resolve'
            - 'IP-CIDR6,fc00::/7,DIRECT,no-resolve'
            - 'IP-CIDR6,fe80::/10,DIRECT,no-resolve'
            - 'DOMAIN-SUFFIX,apps.apple.com,BoostNet'
            - 'DOMAIN-SUFFIX,itunes.apple.com,BoostNet'
            - 'DOMAIN-SUFFIX,blobstore.apple.com,BoostNet'
            - 'DOMAIN,safebrowsing.urlsec.qq.com,DIRECT'
            - 'DOMAIN-SUFFIX,apple.com,DIRECT'
            - 'DOMAIN-SUFFIX,apple-cloudkit.com,DIRECT'
            - 'DOMAIN-SUFFIX,icloud.com,DIRECT'
            - 'DOMAIN-SUFFIX,icloud-content.com,DIRECT'
            - 'DOMAIN-SUFFIX,mzstatic.com,DIRECT'
            - 'DOMAIN-SUFFIX,aaplimg.com,DIRECT'
            - 'DOMAIN-SUFFIX,cdn-apple.com,DIRECT'
            - 'DOMAIN-SUFFIX,akadns.net,DIRECT'
            - 'DOMAIN-KEYWORD,baidu,DIRECT'
            - 'DOMAIN-KEYWORD,alibaba,DIRECT'
            - 'DOMAIN-KEYWORD,alicdn,DIRECT'
            - 'DOMAIN-KEYWORD,alipay,DIRECT'
            - 'DOMAIN-KEYWORD,taobao,DIRECT'
            - 'DOMAIN-KEYWORD,tencent,DIRECT'
            - 'DOMAIN-KEYWORD,bilibili,DIRECT'
            - 'DOMAIN-KEYWORD,weibo,DIRECT'
            - 'DOMAIN-KEYWORD,douyin,DIRECT'
            - 'DOMAIN-KEYWORD,bytedance,DIRECT'
            - 'DOMAIN-KEYWORD,xiaomi,DIRECT'
            - 'DOMAIN-KEYWORD,huawei,DIRECT'
            - 'DOMAIN-KEYWORD,netease,DIRECT'
            - 'DOMAIN-KEYWORD,meituan,DIRECT'
            - 'DOMAIN-KEYWORD,pinduoduo,DIRECT'
            - 'DOMAIN-KEYWORD,kuaishou,DIRECT'
            - 'DOMAIN-KEYWORD,jingdong,DIRECT'
            - 'DOMAIN-KEYWORD,officecdn,DIRECT'
            - 'DOMAIN-SUFFIX,qq.com,DIRECT'
            - 'DOMAIN-SUFFIX,weixin.com,DIRECT'
            - 'DOMAIN-SUFFIX,wechat.com,DIRECT'
            - 'DOMAIN-SUFFIX,gtimg.com,DIRECT'
            - 'DOMAIN-SUFFIX,qcloud.com,DIRECT'
            - 'DOMAIN-SUFFIX,myqcloud.com,DIRECT'
            - 'DOMAIN-SUFFIX,qpic.cn,DIRECT'
            - 'DOMAIN-SUFFIX,tenpay.com,DIRECT'
            - 'DOMAIN-SUFFIX,tmall.com,DIRECT'
            - 'DOMAIN-SUFFIX,jd.com,DIRECT'
            - 'DOMAIN-SUFFIX,360buyimg.com,DIRECT'
            - 'DOMAIN-SUFFIX,iqiyi.com,DIRECT'
            - 'DOMAIN-SUFFIX,youku.com,DIRECT'
            - 'DOMAIN-SUFFIX,ykimg.com,DIRECT'
            - 'DOMAIN-SUFFIX,tudou.com,DIRECT'
            - 'DOMAIN-SUFFIX,acfun.tv,DIRECT'
            - 'DOMAIN-SUFFIX,hdslb.com,DIRECT'
            - 'DOMAIN-SUFFIX,sohu.com,DIRECT'
            - 'DOMAIN-SUFFIX,sogou.com,DIRECT'
            - 'DOMAIN-SUFFIX,zhihu.com,DIRECT'
            - 'DOMAIN-SUFFIX,zhimg.com,DIRECT'
            - 'DOMAIN-SUFFIX,douban.com,DIRECT'
            - 'DOMAIN-SUFFIX,doubanio.com,DIRECT'
            - 'DOMAIN-SUFFIX,163.com,DIRECT'
            - 'DOMAIN-SUFFIX,126.com,DIRECT'
            - 'DOMAIN-SUFFIX,126.net,DIRECT'
            - 'DOMAIN-SUFFIX,127.net,DIRECT'
            - 'DOMAIN-SUFFIX,yeah.net,DIRECT'
            - 'DOMAIN-SUFFIX,sina.com,DIRECT'
            - 'DOMAIN-SUFFIX,sinaimg.cn,DIRECT'
            - 'DOMAIN-SUFFIX,ximalaya.com,DIRECT'
            - 'DOMAIN-SUFFIX,xmcdn.com,DIRECT'
            - 'DOMAIN-SUFFIX,csdn.net,DIRECT'
            - 'DOMAIN-SUFFIX,gitee.com,DIRECT'
            - 'DOMAIN-SUFFIX,jianshu.com,DIRECT'
            - 'DOMAIN-SUFFIX,cnblogs.com,DIRECT'
            - 'DOMAIN-SUFFIX,oschina.net,DIRECT'
            - 'DOMAIN-SUFFIX,ele.me,DIRECT'
            - 'DOMAIN-SUFFIX,ctrip.com,DIRECT'
            - 'DOMAIN-SUFFIX,suning.com,DIRECT'
            - 'DOMAIN-SUFFIX,dianping.com,DIRECT'
            - 'DOMAIN-SUFFIX,amap.com,DIRECT'
            - 'DOMAIN-SUFFIX,autonavi.com,DIRECT'
            - 'DOMAIN-SUFFIX,mi.com,DIRECT'
            - 'DOMAIN-SUFFIX,miui.com,DIRECT'
            - 'DOMAIN-SUFFIX,ifeng.com,DIRECT'
            - 'DOMAIN-SUFFIX,youdao.com,DIRECT'
            - 'DOMAIN-SUFFIX,iciba.com,DIRECT'
            - 'DOMAIN-SUFFIX,xunlei.com,DIRECT'
            - 'DOMAIN-SUFFIX,smzdm.com,DIRECT'
            - 'DOMAIN-SUFFIX,sspai.com,DIRECT'
            - 'DOMAIN-SUFFIX,36kr.com,DIRECT'
            - 'DOMAIN-SUFFIX,speedtest.net,DIRECT'
            - 'DOMAIN-SUFFIX,microsoft.com,DIRECT'
            - 'DOMAIN-SUFFIX,microsoftonline.com,DIRECT'
            - 'DOMAIN-SUFFIX,office.com,DIRECT'
            - 'DOMAIN-SUFFIX,office365.com,DIRECT'
            - 'DOMAIN-SUFFIX,windows.com,DIRECT'
            - 'DOMAIN-SUFFIX,windowsupdate.com,DIRECT'
            - 'DOMAIN-SUFFIX,live.com,DIRECT'
            - 'DOMAIN-SUFFIX,msn.com,DIRECT'
            - 'DOMAIN-SUFFIX,cn,DIRECT'
            - 'DOMAIN-KEYWORD,-cn,DIRECT'
            - 'DOMAIN-KEYWORD,google,BoostNet'
            - 'DOMAIN-KEYWORD,gmail,BoostNet'
            - 'DOMAIN-KEYWORD,youtube,BoostNet'
            - 'DOMAIN-KEYWORD,facebook,BoostNet'
            - 'DOMAIN-KEYWORD,twitter,BoostNet'
            - 'DOMAIN-KEYWORD,instagram,BoostNet'
            - 'DOMAIN-KEYWORD,whatsapp,BoostNet'
            - 'DOMAIN-KEYWORD,telegram,BoostNet'
            - 'DOMAIN-KEYWORD,github,BoostNet'
            - 'DOMAIN-KEYWORD,blogspot,BoostNet'
            - 'DOMAIN-KEYWORD,dropbox,BoostNet'
            - 'DOMAIN-KEYWORD,wikipedia,BoostNet'
            - 'DOMAIN-KEYWORD,pinterest,BoostNet'
            - 'DOMAIN-KEYWORD,discord,BoostNet'
            - 'DOMAIN-KEYWORD,openai,BoostNet'
            - 'DOMAIN-KEYWORD,anthropic,BoostNet'
            - 'DOMAIN-KEYWORD,netflix,BoostNet'
            - 'DOMAIN-KEYWORD,spotify,BoostNet'
            - 'DOMAIN-KEYWORD,amazon,BoostNet'
            - 'DOMAIN-SUFFIX,t.co,BoostNet'
            - 'DOMAIN-SUFFIX,x.com,BoostNet'
            - 'DOMAIN-SUFFIX,twimg.com,BoostNet'
            - 'DOMAIN-SUFFIX,fb.me,BoostNet'
            - 'DOMAIN-SUFFIX,fbcdn.net,BoostNet'
            - 'DOMAIN-SUFFIX,youtu.be,BoostNet'
            - 'DOMAIN-SUFFIX,ytimg.com,BoostNet'
            - 'DOMAIN-SUFFIX,gstatic.com,BoostNet'
            - 'DOMAIN-SUFFIX,ggpht.com,BoostNet'
            - 'DOMAIN-SUFFIX,googlevideo.com,BoostNet'
            - 'DOMAIN-SUFFIX,v2ex.com,BoostNet'
            - 'DOMAIN-SUFFIX,medium.com,BoostNet'
            - 'DOMAIN-SUFFIX,reddit.com,BoostNet'
            - 'DOMAIN-SUFFIX,redd.it,BoostNet'
            - 'DOMAIN-SUFFIX,imgur.com,BoostNet'
            - 'DOMAIN-SUFFIX,pixiv.net,BoostNet'
            - 'DOMAIN-SUFFIX,nytimes.com,BoostNet'
            - 'DOMAIN-SUFFIX,nyt.com,BoostNet'
            - 'DOMAIN-SUFFIX,bbc.com,BoostNet'
            - 'DOMAIN-SUFFIX,bbc.co.uk,BoostNet'
            - 'DOMAIN-SUFFIX,steamcommunity.com,BoostNet'
            - 'DOMAIN-SUFFIX,twitch.tv,BoostNet'
            - 'DOMAIN-SUFFIX,vimeo.com,BoostNet'
            - 'DOMAIN-SUFFIX,tumblr.com,BoostNet'
            - 'DOMAIN-SUFFIX,linkedin.com,BoostNet'
            - 'DOMAIN-SUFFIX,licdn.com,BoostNet'
            - 'DOMAIN-SUFFIX,mega.nz,BoostNet'
            - 'DOMAIN-SUFFIX,archive.org,BoostNet'
            - 'DOMAIN-SUFFIX,wikimedia.org,BoostNet'
            - 'DOMAIN-SUFFIX,soundcloud.com,BoostNet'
            - 'IP-CIDR,91.108.4.0/22,BoostNet,no-resolve'
            - 'IP-CIDR,91.108.8.0/21,BoostNet,no-resolve'
            - 'IP-CIDR,91.108.12.0/22,BoostNet,no-resolve'
            - 'IP-CIDR,91.108.16.0/22,BoostNet,no-resolve'
            - 'IP-CIDR,91.108.56.0/22,BoostNet,no-resolve'
            - 'IP-CIDR,149.154.160.0/20,BoostNet,no-resolve'
            - 'IP-CIDR6,2001:67c:4e8::/48,BoostNet,no-resolve'
            - 'IP-CIDR6,2001:b28:f23d::/48,BoostNet,no-resolve'
            - 'IP-CIDR6,2001:b28:f23f::/48,BoostNet,no-resolve'
            - 'GEOIP,CN,DIRECT'
            - 'MATCH,BoostNet'
        """
    }

    /// 解析代理 URI 并返回 (name, yaml) 元组
    private func parseProxyUri(_ uri: String) -> (name: String, yaml: String)? {
        // URL decode helper
        func decodeURL(_ string: String) -> String {
            guard let data = string.data(using: .utf8),
                  let result = try? JSONDecoder().decode(DecodableValue.self, from: data) else {
                return string.removingPercentEncoding ?? string
            }
            return result.value
        }

        struct DecodableValue: Decodable {
            let value: String
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                value = try container.decode(String.self)
            }
        }

        // 解析 URI
        guard let url = URL(string: uri),
              let scheme = url.scheme,
              ["anytls", "ss", "vmess", "vless", "trojan", "hysteria", "hysteria2", "tuic", "wireguard", "shadowsocks"].contains(scheme.lowercased()) else {
            return nil
        }

        // 提取节点名称（fragment 部分）
        var name = url.fragment ?? ""
        name = decodeURL(name)
        if name.isEmpty {
            name = "Unknown"
        }

        // 提取认证信息（user@password 部分）
        let userInfo = url.user ?? ""
        let password = url.password ?? userInfo  // 有些格式用整个 userInfo 作为密码

        // 提取主机和端口
        let host = url.host ?? ""
        let port = url.port ?? (scheme == "anytls" ? 443 : 80)

        // 解析查询参数
        var sni = ""
        var insecure = false
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for item in queryItems {
            switch item.name.lowercased() {
            case "sni":
                sni = item.value ?? ""
            case "insecure":
                insecure = item.value == "1" || item.value == "true"
            default:
                break
            }
        }

        let type = scheme.lowercased() == "shadowsocks" ? "ss" : scheme.lowercased()

        // 生成 YAML
        if type == "ss" {
            // Shadowsocks 格式特殊
            return (name, "- { name: '\(name)', type: ss, server: \(host), port: \(port), cipher: chacha20-ietf-poly1305, password: \(password), udp: true }")
        } else if type == "anytls" {
            // AnyTLS
            let skipCert = insecure ? "true" : "false"
            return (name, "- { name: '\(name)', type: anytls, server: \(host), port: \(port), password: \(password), sni: \(sni), skip-cert-verify: \(skipCert), udp: true }")
        } else {
            // 其他类型
            return (name, "- { name: '\(name)', type: \(type), server: \(host), port: \(port), password: \(password), udp: true }")
        }
    }

    /// Base64 解码
    private func base64Decode(_ string: String) throws -> String {
        // 移除可能的 data URI 前缀
        var base64String = string
        if let range = string.range(of: "base64,") {
            base64String = String(string[range.upperBound...])
        }

        guard let data = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
            throw ConfigError.invalidSubscriptionURL
        }

        guard let decodedString = String(data: data, encoding: .utf8) else {
            throw ConfigError.invalidSubscriptionURL
        }

        return decodedString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: configDirectory.path) {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        }
    }

    /// 解析 config.yaml 获取 proxy-groups 的顺序
    func parseProxyGroupsOrder() -> [(name: String, proxies: [String])] {
        guard let content = try? String(contentsOf: runtimeConfigFile, encoding: .utf8) else {
            return []
        }

        var result: [(name: String, proxies: [String])] = []
        let lines = content.components(separatedBy: .newlines)

        var inProxyGroups = false
        var currentGroupName: String?
        var currentProxies: [String] = []
        var inInlineFormat = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("proxy-groups:") {
                inProxyGroups = true
                continue
            }

            if !inProxyGroups {
                continue
            }

            // 检测内联格式: - { name: xxx, type: xxx, proxies: [aaa, bbb] }
            if trimmed.hasPrefix("- {") && trimmed.contains("name:") && trimmed.contains("proxies:") {
                // 保存上一个 group
                if let name = currentGroupName, !currentProxies.isEmpty {
                    result.append((name: name, proxies: currentProxies))
                }

                // 解析内联格式
                if let (name, proxies) = parseInlineGroup(trimmed) {
                    currentGroupName = name
                    currentProxies = proxies
                }
                continue
            }

            // 检测多行格式的 group 开始
            if trimmed == "-" || trimmed.hasPrefix("- name:") {
                // 保存上一个 group
                if let name = currentGroupName, !currentProxies.isEmpty {
                    result.append((name: name, proxies: currentProxies))
                }
                currentGroupName = nil
                currentProxies = []
                inInlineFormat = false

                if trimmed.hasPrefix("- name:") {
                    let name = trimmed.replacingOccurrences(of: "- name:", with: "")
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    currentGroupName = name
                }
                continue
            }

            // 多行格式: name: xxx
            if trimmed.hasPrefix("name:") && currentGroupName == nil {
                let name = trimmed.replacingOccurrences(of: "name:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                currentGroupName = name
                continue
            }

            // 多行格式: proxies: 开始
            if trimmed.hasPrefix("proxies:") {
                if trimmed.hasPrefix("proxies: [") && trimmed.contains("]") {
                    // 内联数组格式: proxies: [aaa, bbb]
                    let arrayContent = extractArrayContent(trimmed)
                    currentProxies = parseProxyArray(arrayContent)
                } else if trimmed == "proxies:" || trimmed == "proxies:" {
                    // 多行数组开始
                    inInlineFormat = true
                }
                continue
            }

            // 多行格式: - xxx
            if inInlineFormat && trimmed.hasPrefix("- ") {
                let proxy = trimmed.replacingOccurrences(of: "- ", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !proxy.isEmpty {
                    currentProxies.append(proxy)
                }
                continue
            }

            // 检测多行数组结束
            if inInlineFormat && !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("name:") && !trimmed.hasPrefix("type:") {
                inInlineFormat = false
            }
        }

        // 保存最后一个 group
        if let name = currentGroupName, !currentProxies.isEmpty {
            result.append((name: name, proxies: currentProxies))
        }

        return result
    }

    /// 解析内联格式 group: - { name: xxx, type: xxx, proxies: [aaa, bbb] }
    private func parseInlineGroup(_ line: String) -> (name: String, proxies: [String])? {
        // 提取 name
        var name = ""
        if let nameRange = line.range(of: "name:") {
            let afterName = line[nameRange.upperBound...]
            if let commaRange = afterName.firstIndex(of: ",") {
                name = String(afterName[..<commaRange]).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        }

        // 提取 proxies 数组
        var proxies: [String] = []
        if let proxiesRange = line.range(of: "proxies:") {
            let afterProxies = line[proxiesRange.upperBound...]
            if let bracketStart = afterProxies.firstIndex(of: "["),
               let bracketEnd = afterProxies.lastIndex(of: "]") {
                let arrayContent = String(afterProxies[bracketStart...bracketEnd])
                let extracted = extractArrayContent("proxies: \(arrayContent)")
                proxies = parseProxyArray(extracted)
            }
        }

        guard !name.isEmpty else { return nil }
        return (name, proxies)
    }

    /// 从 "proxies: [xxx, yyy]" 格式中提取数组内容
    private func extractArrayContent(_ line: String) -> String {
        if let bracketStart = line.firstIndex(of: "["),
           let bracketEnd = line.lastIndex(of: "]") {
            return String(line[bracketStart...bracketEnd])
        }
        return ""
    }

    /// 解析 proxy 数组字符串 [xxx, yyy, zzz]
    private func parseProxyArray(_ arrayString: String) -> [String] {
        var result: [String] = []
        let content = arrayString.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        // 按逗号分割
        var current = ""
        var depth = 0
        var inQuote = false

        for char in content {
            if char == "'" || char == "\"" {
                inQuote.toggle()
            } else if char == "[" || char == "]" {
                depth += (char == "[" ? 1 : -1)
            } else if char == "," && depth == 0 && !inQuote {
                let proxy = current.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                if !proxy.isEmpty {
                    result.append(proxy)
                }
                current = ""
                continue
            }
            current.append(char)
        }

        // 最后一个
        let lastProxy = current.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        if !lastProxy.isEmpty {
            result.append(lastProxy)
        }

        return result
    }
}

enum ConfigError: LocalizedError {
    case invalidSubscriptionURL
    case invalidResponse(statusCode: Int? = nil)
    case emptySubscription
    case subscriptionBlocked
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidSubscriptionURL:
            return "订阅地址无效"
        case .invalidResponse(let statusCode):
            if let statusCode {
                return "订阅地址返回了无效响应，HTTP \(statusCode)"
            }
            return "订阅地址返回了无效响应"
        case .emptySubscription:
            return "订阅内容为空"
        case .subscriptionBlocked:
            return "订阅请求被服务端拦截"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        }
    }
}
