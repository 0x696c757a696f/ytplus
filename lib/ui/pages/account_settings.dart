import 'package:flutter/material.dart';

import '../../app/account_controller.dart';
import '../../google_auth.dart';
import '../../youtube_account.dart';
import '../common.dart';
import '../theme.dart';
import '../../l10n/l10n.dart';

/// Google sign-in, sync and the OAuth client used for it.
class AccountSettings extends StatelessWidget {
  const AccountSettings({super.key, required this.account, required this.note});
  final AccountController? account;
  final TextStyle note;

  @override
  Widget build(BuildContext context) {
    final account = this.account;
    if (account == null) return ListTile(title: Text(tr('正在准备…')));
    final colors = context.colors;
    final error = account.error;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      switch (account.state) {
        AccountState.signedIn => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                child: Icon(Icons.person_rounded, color: colors.onPrimaryContainer),
              ),
              title: Text(account.name ?? tr('YouTube 账号')),
              trailing: account.canWrite ? null : FilledButton.tonal(onPressed: account.signIn, child: Text(tr('重新登录以启用点赞和评论'))),
              subtitle: Text(account.syncing
                  ? tr('正在同步订阅和播放列表…')
                  : account.lastSync == null
                      ? tr('已登录，尚未同步')
                      : tr('上次同步：{0} {1}', [formatDate(account.lastSync!), _time(account.lastSync!)])),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: account.syncing ? null : account.sync,
                  icon: account.syncing ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.sync_rounded),
                  label: Text(tr('立即同步')),
                ),
                OutlinedButton(onPressed: () => _confirmSignOut(context, account), child: Text(tr('退出登录'))),
              ]),
            ),
          ]),
        AccountState.signingIn => ListTile(
            leading: const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
            title: Text(tr('请在浏览器中完成登录')),
            subtitle: Text(tr('已在默认浏览器打开 Google 登录页，完成后会自动回到这里。')),
            trailing: TextButton(onPressed: account.cancelSignIn, child: Text(tr('取消'))),
          ),
        AccountState.signedOut => ListTile(
            leading: Icon(Icons.account_circle_outlined, color: colors.primary),
            title: Text(tr('Google 账号')),
            subtitle: Text(account.client == null ? tr('这个版本没有内置 Google 客户端，需要先在下方填写你自己的客户端。') : tr('登录后可以导入订阅、播放列表和喜欢的视频，也可以点赞、评论、保存到播放列表和订阅。')),
            trailing: FilledButton.icon(
              onPressed: account.client == null ? null : account.signIn,
              icon: const Icon(Icons.login_rounded),
              label: Text(tr('登录')),
            ),
          ),
      },
      if (error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: error == YouTubeApiException.apiNotEnabled
              ? ErrorBanner(error, onRetry: () => openExternal(YouTubeApiException.enableApiUrl), retryLabel: tr('去启用'))
              : ErrorBanner(error),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
        child: Text(
          tr('登录完全可选，不登录也能正常搜索和播放。登录后读取订阅和播放列表并复制到本机；只有你在 Lumtub 里点赞、点踩、评论、保存到播放列表或订阅时才会修改账号，不会上传本机的观看记录。登录凭据用 Windows 数据保护加密后保存在本机，只有当前 Windows 用户能解密。\nYouTube 官方接口不提供观看历史和首页推荐，也不支持给社区帖子点赞或评论；首页的“为你推荐”在本机计算，会参考同步过来的喜欢的视频和订阅。视频播放不使用这个账号，会员或年龄限制视频不一定能播放。'),
          style: note,
        ),
      ),
      _ClientSettings(account: account, note: note),
    ]);
  }

  static String _time(DateTime time) => '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  Future<void> _confirmSignOut(BuildContext context, AccountController account) async {
    final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(tr('退出 Google 账号？')),
      content: Text(tr('会删除本机保存的登录凭据，并通知 Google 撤销 Lumtub 的授权。已经导入的关注频道和播放列表会保留。')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('退出登录'))),
      ],
    ));
    if (confirmed == true) await account.signOut();
  }
}

/// The user's own Google Cloud OAuth client, for builds without one or for
/// people who prefer their own quota.
class _ClientSettings extends StatefulWidget {
  const _ClientSettings({required this.account, required this.note});
  final AccountController account;
  final TextStyle note;

  @override
  State<_ClientSettings> createState() => _ClientSettingsState();
}

class _ClientSettingsState extends State<_ClientSettings> {
  late final _id = TextEditingController(text: widget.account.customClient?.id ?? '');
  late final _secret = TextEditingController(text: widget.account.customClient?.secret ?? '');

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.account;
    final custom = account.customClient != null;
    final candidate = OAuthClientConfig(_id.text.trim(), _secret.text.trim());
    return ExpansionTile(
      key: const PageStorageKey('expand:client'),
      leading: const Icon(Icons.key_outlined),
      title: Text(tr('自定义 Google 客户端')),
      subtitle: Text(custom ? tr('正在使用你自己的客户端') : account.client == null ? tr('未设置') : tr('正在使用内置客户端')),
      initiallyExpanded: account.client == null,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('1. 在 Google Cloud 控制台新建项目，然后在这个项目里启用 YouTube Data API v3（下面第一个按钮，打开后确认顶部选中的是这个项目，再点“启用”）。没有启用的话，登录后会提示“还没有启用 YouTube Data API v3”。\n2. 配置 OAuth 同意屏幕，用户类型选“外部”，把自己的 Google 账号加为测试用户。\n3. 在“凭据”里创建 OAuth 客户端 ID，应用类型选“桌面应用”，把客户端 ID 和密钥填到下面。'),
          style: widget.note,
        ),
        const SizedBox(height: 4),
        Wrap(spacing: 8, children: [
          TextButton.icon(
            onPressed: () => openExternal(YouTubeApiException.enableApiUrl),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(tr('启用 YouTube Data API v3')),
          ),
          TextButton.icon(
            onPressed: () => openExternal('https://console.cloud.google.com/apis/credentials'),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(tr('创建 OAuth 客户端')),
          ),
        ]),
        const SizedBox(height: 8),
        // Each field gets its own storage key: a text field scrolls, and
        // without one its scroll offset would be read back from the
        // tile's own saved open/closed flag, a bool, and fail to build.
        TextField(key: const PageStorageKey('client:id'), controller: _id, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: tr('客户端 ID'), hintText: '…apps.googleusercontent.com')),
        const SizedBox(height: 10),
        TextField(key: const PageStorageKey('client:secret'), controller: _secret, onChanged: (_) => setState(() {}), obscureText: true, decoration: InputDecoration(labelText: tr('客户端密钥'))),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.tonal(
            onPressed: candidate.isValid ? () => _apply(candidate) : null,
            child: Text(tr('保存')),
          ),
          if (custom)
            TextButton(
              onPressed: () {
                _id.clear();
                _secret.clear();
                _apply(null);
              },
              child: Text(OAuthClientConfig.builtIn.isValid ? tr('改回内置客户端') : tr('清除')),
            ),
        ]),
      ],
    );
  }

  Future<void> _apply(OAuthClientConfig? config) async {
    final messenger = ScaffoldMessenger.of(context);
    final wasSignedIn = widget.account.signedIn;
    await widget.account.setCustomClient(config);
    messenger.showSnackBar(SnackBar(content: Text(wasSignedIn ? tr('客户端已更换，请重新登录') : tr('客户端已保存'))));
  }
}

/// Account entry in the top bar.
class AccountButton extends StatelessWidget {
  const AccountButton({super.key, required this.account, required this.onOpenSettings});
  final AccountController? account;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final account = this.account;
    final signedIn = account?.signedIn ?? false;
    final name = account?.name ?? '';
    final avatar = CircleAvatar(
      radius: 16,
      backgroundColor: signedIn ? colors.primaryContainer : colors.surfaceContainerHighest,
      child: signedIn && name.isNotEmpty
          ? Text(String.fromCharCode(name.runes.first).toUpperCase(), style: TextStyle(fontWeight: FontWeight.w600, color: colors.onPrimaryContainer))
          : Icon(Icons.person_outline_rounded, size: 20, color: colors.onSurfaceVariant),
    );
    if (account == null || !signedIn) {
      return IconButton(tooltip: tr('登录 Google 账号（可选）'), onPressed: onOpenSettings, icon: avatar);
    }
    return PopupMenuButton<String>(
      tooltip: name.isEmpty ? tr('账号') : name,
      icon: avatar,
      onSelected: (value) => value == 'sync' ? account.sync() : onOpenSettings(),
      itemBuilder: (context) => [
        PopupMenuItem(enabled: false, child: Text(name.isEmpty ? tr('YouTube 账号') : name, style: context.text.titleSmall)),
        PopupMenuItem(value: 'sync', enabled: !account.syncing, child: ListTile(dense: true, leading: const Icon(Icons.sync_rounded), title: Text(account.syncing ? tr('正在同步…') : tr('同步订阅和播放列表')))),
        PopupMenuItem(value: 'settings', child: ListTile(dense: true, leading: Icon(Icons.manage_accounts_outlined), title: Text(tr('账号设置')))),
      ],
    );
  }
}
