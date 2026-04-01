# iClash 流程时序图

## 1. APP 启动流程

```mermaid
sequenceDiagram
    participant System
    participant App as iClashApp
    participant Config as ConfigManager
    participant Mihomo as MihomoService
    participant Proxy as 系统代理

    System->>App: applicationDidFinishLaunching

    App->>Config: ensureBaseConfigurationExists()
    App->>App: setupStatusBar()
    App->>Config: runtimeConfigFileExists?

    alt config.yaml 不存在
        App-->>System: 不启动服务
    else config.yaml 存在
        App->>App: startProxyOnLaunch()

        App->>Mihomo: start()
        Mihomo->>Config: prepareRuntimeConfigFile()
        Config-->>Mihomo: config.yaml 路径
        Mihomo->>Mihomo: 启动 mihomo 进程
        Mihomo->>Mihomo: fetchKernelVersion()
        Mihomo->>Proxy: setSystemProxy(enabled: true)

        alt 启动成功
            Mihomo-->>App: 成功
            App->>App: refreshProxyList()
            App->>App: refreshProxySubmenu()
        else 启动失败
            Mihomo-->>App: 失败
            App->>App: showError("启动代理失败")
        end
    end
```

## 2. 保存 URL 流程

```mermaid
sequenceDiagram
    participant User
    participant App as iClashApp
    participant Config as ConfigManager
    participant Mihomo as MihomoService
    participant Proxy as 系统代理

    User->>App: 点击保存
    App->>Config: downloadAndValidateConfig(url)

    alt 下载成功
        Config-->>App: config.yaml 路径
        App->>Config: subscriptionURL = url
        App->>Mihomo: stop()
        Mihomo->>Proxy: setSystemProxy(enabled: false)
        Mihomo->>Mihomo: 终止进程

        App->>Mihomo: start()
        Mihomo->>Mihomo: 启动新进程
        Mihomo->>Proxy: setSystemProxy(enabled: true)

        alt 启动成功
            App->>App: 关闭窗口
            App->>App: refreshProxyList()
            App->>App: refreshProxySubmenu()
        else 启动失败
            App->>App: showError("启动代理失败")
        end

    else 下载失败
        Config-->>App: 抛出错误
        App->>App: showError(错误信息)
    end
```

## 3. 点击菜单栏流程

```mermaid
sequenceDiagram
    participant User
    participant App as iClashApp
    participant Mihomo as MihomoService

    User->>App: 点击菜单栏图标
    App->>App: menuWillOpen()
    App->>App: refreshProxyList()

    alt subscriptionURL 为空
        App->>App: cachedProxyGroups = []
        App->>App: refreshProxySubmenu()
    else subscriptionURL 不为空
        App->>Mihomo: fetchProxies()
        Mihomo-->>App: 代理列表
        App->>App: 缓存并刷新菜单
    end
```

## 4. 内核版本更新流程

```mermaid
sequenceDiagram
    participant User
    participant App as iClashApp
    participant Menu as MenuController
    participant Updater as KernelUpdater
    participant Mihomo as MihomoService
    participant GitHub as GitHub API

    User->>Menu: 点击"内核版本"
    Menu->>Mihomo: kernelVersion (当前版本)
    Menu->>GitHub: fetchLatestVersion()
    GitHub-->>Menu: 最新版本 (v1.19.x)

    alt 版本相同
        Menu-->>User: 显示"当前: v1.19.x, 最新: v1.19.x"
        Menu->>User: 只显示"关闭"按钮
    else 版本不同
        Menu-->>User: 显示"当前: v1.19.x, 最新: v1.19.y"
        Menu->>User: 显示"更新""关闭"按钮

        User->>Menu: 点击"更新"
        Menu->>App: updateKernel()
        App->>Updater: updateKernel()

        Updater->>GitHub: 下载 mihomo-darwin-arm64-v{version}.gz
        GitHub-->>Updater: 文件内容

        Updater->>Mihomo: stop()
        Mihomo->>Mihomo: 终止进程
        Mihomo->>Proxy: setSystemProxy(enabled: false)

        Updater->>Updater: 解压并替换内核文件
        Updater-->>App: 更新成功

        App->>User: 提示"内核更新成功，请重启"
    end
```

## 5. 退出应用流程

```mermaid
sequenceDiagram
    participant User
    participant App as iClashApp
    participant Mihomo as MihomoService
    participant Proxy as 系统代理

    User->>App: 点击"退出"
    App->>Mihomo: stop()

    Mihomo->>Proxy: setSystemProxy(enabled: false)
    Proxy-->>Mihomo: 关闭成功

    Mihomo->>Mihomo: 终止进程
    App->>System: NSApplication.terminate(nil)
```

## 核心逻辑总结

| 场景 | 行为 |
|------|------|
| 启动 APP | config.yaml 存在 → 启服务；不存在 → 不启动 |
| 保存 URL | 下载成功 → 保存 URL → 停服务 → 启服务 → 关窗口 → 刷新菜单 |
| 保存 URL | 下载失败 → 提示错误，窗口保持，不保存 URL，无其他动作 |
| 点击菜单栏 | 每次点击 → 刷新代理列表 |
| 点击"内核版本" | 显示当前和最新内核版本，版本不同时提供更新按钮 |
| 点击"退出" | 关闭系统代理 → 终止 mihomo 进程 → 退出应用 |
