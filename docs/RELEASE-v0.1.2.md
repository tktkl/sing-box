# sb-manager v0.1.2

节点查看和导入预览统一显示真实字段值。

- `sb info`、`sb debug` 显示完整实际数据，包括 UUID、密码、REALITY 密钥和出口参数。
- 菜单中的「完整节点信息」显示与 `sb info` 相同的完整记录。
- 旧脚本配置的导入预览显示原始凭据，不再输出脱敏标记。
- 无需额外开关，升级后即可使用。

```bash
sudo sb update sh
sudo sb
```

root 用户省略 `sudo`。不带版本号会更新到最新稳定 Release；升级保留已有节点和运行凭据。
