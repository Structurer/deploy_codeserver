# code Server + Cloudflare Tunnel 部署指南

本仓库提供了一个自动化部署脚本，用于在 Ubuntu 服务器上安装和配置 code Server + Cloudflare Tunnel。

## 功能特性

- ✅ 自动安装和配置 code Server
- ✅ 自动安装和配置 Cloudflare Tunnel
- ✅ 交互式密码设置
- ✅ 自动检测和选择已授权的 Cloudflare 域名
- ✅ 子域名前缀配置（默认值：code）
- ✅ 服务开机自启设置
- ✅ 详细的错误处理和状态反馈

## 系统要求

- Ubuntu 20.04 LTS 或更高版本
- 至少 1GB RAM
- 至少 10GB 磁盘空间
- 可访问互联网
- Root 权限

## 快速开始

### 直接执行（推荐）

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Structurer/deploy_codeserver/main/deploy_codeserver.sh)"
```

### 备用sh执行（en_US)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Structurer/deploy_codeserver/main/deploy_codeserver_en.sh)"
```


## 执行流程

1. **系统准备**
   - 更新系统包
   - 安装必要依赖

2. **code Server 部署**
   - 安装 code Server
   - 交互式输入登录密码（两次确认）
   - 启动并启用 code Server 服务

3. **Cloudflare Tunnel 部署**
   - 安装 Cloudflare Tunnel 客户端
   - Cloudflare 账户授权（需要浏览器登录）
   - 提取并选择已授权的域名
   - 配置子域名前缀（默认：code）
   - 创建并配置 Cloudflare Tunnel
   - 启动并启用 Cloudflare Tunnel 服务
   - 绑定域名到 Tunnel

4. **完成部署**
   - 验证服务状态
   - 显示访问信息

## 访问信息

部署完成后，您可以通过以下地址访问 code Server：

- **自定义域名**：https://[子域名].[主域名]（ 例如：https://code.example.com ）
- **Cloudflare Tunnel 默认地址**：https://[tunnel-id].cfargotunnel.com

## 注意事项

1. **权限要求**
   - 执行脚本时需要 root 权限

2. **网络连接**
   - 确保服务器可以访问互联网
   - 确保服务器可以访问 Cloudflare 服务

3. **Cloudflare 授权**
   - 在授权步骤中，需要在浏览器中打开提供的 URL 并登录 Cloudflare 账户
   - 授权完成后，返回终端按回车键继续

4. **域名配置**
   - 确保您选择的域名已经添加到 Cloudflare 账户中
   - 如果域名的 DNS 记录已存在，需要先在 Cloudflare 仪表盘中删除冲突的记录

5. **服务管理**

   ```bash
   # 重启 code Server 服务
   systemctl restart code-server@root

   # 重启 Cloudflare Tunnel 服务
   systemctl restart cloudflared

   # 查看服务状态
   systemctl status code-server@root
   systemctl status cloudflared
   ```

## 故障排查

### 常见问题

1. **Cloudflare 授权失败**
   - 确保您在浏览器中完成了授权操作
   - 确保使用的是正确的 Cloudflare 账户

2. **域名绑定失败**
   - 错误信息：`Failed to add route: code: 1003, reason: Failed to create record...`
   - 解决方案：在 Cloudflare 仪表盘中删除冲突的 DNS 记录，然后重新运行脚本

3. **服务启动失败**
   - 检查服务状态：`systemctl status [service-name]`
   - 查看服务日志：`journalctl -u [service-name]`

### 日志查看

```bash
# 查看 code Server 日志
journalctl -u code-server@root

# 查看 Cloudflare Tunnel 日志
journalctl -u cloudflared
```

## 更新脚本

要获取最新版本的脚本，只需重新运行下载命令：

```bash
curl -fsSL https://raw.githubusercontent.com/Structurer/deploy_codeserver/main/deploy_codeserver.sh | bash
```

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request 来改进这个项目！
