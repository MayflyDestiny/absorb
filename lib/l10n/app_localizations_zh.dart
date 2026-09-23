// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'A B S O R B';

  @override
  String get online => '在线';

  @override
  String get offline => '离线';

  @override
  String get stillOffline => '仍处于离线状态。点击重试。';

  @override
  String get retry => '重试';

  @override
  String get listsNone => '暂无收藏集或播放列表';

  @override
  String get listsNoneHint => '收藏集和播放列表是在您的 Audiobookshelf 服务器上创建的，并会显示在这里。';

  @override
  String get listsLoadFailed => '无法加载您的列表';

  @override
  String get listsLoadFailedHint => 'Absorb 无法连接到您的服务器以获取收藏集和播放列表。';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get remove => '移除';

  @override
  String get save => '保存';

  @override
  String get done => '完成';

  @override
  String get edit => '编辑';

  @override
  String get search => '搜索';

  @override
  String get chapterIndex => '选集';

  @override
  String get apply => '应用';

  @override
  String get enable => '启用';

  @override
  String get clear => '清除';

  @override
  String get off => '关闭';

  @override
  String get disabled => '已禁用';

  @override
  String get later => '稍后';

  @override
  String get gotIt => '知道了';

  @override
  String get preview => '预览';

  @override
  String get or => '或';

  @override
  String get file => '文件';

  @override
  String get more => '更多';

  @override
  String get unknown => '未知';

  @override
  String get untitled => '无标题';

  @override
  String get noThanks => '不了，谢谢';

  @override
  String get stay => '保留';

  @override
  String get homeTitle => '首页';

  @override
  String get continueListening => '继续收听';

  @override
  String get continueSeries => '继续收听系列';

  @override
  String get recentlyAdded => '最近添加';

  @override
  String get listenAgain => '重新收听';

  @override
  String get discover => '发现';

  @override
  String get newEpisodes => '最新单集';

  @override
  String get downloads => '下载';

  @override
  String get noDownloadedBooks => '暂无已下载书籍';

  @override
  String get yourLibraryIsEmpty => '您的媒体库空空如也';

  @override
  String get downloadBooksWhileOnline => '在线时下载书籍以离线收听';

  @override
  String get customizeHome => '自定义首页';

  @override
  String get dragToReorderTapEye => '拖动排序，点击眼睛图标显示/隐藏';

  @override
  String get loginTagline => '开始收听之旅';

  @override
  String get loginConnectToServer => '连接到您的服务器';

  @override
  String get loginServerAddress => '服务器地址';

  @override
  String get loginServerHint => 'my.server.com';

  @override
  String get loginServerHelper => '也支持 IP:端口 格式（例如 192.168.1.5:13378）';

  @override
  String get loginCouldNotReachServer => '无法连接到服务器';

  @override
  String get loginAdvanced => '高级';

  @override
  String get loginCustomHttpHeaders => '自定义 HTTP 请求头';

  @override
  String get loginCustomHeadersDescription =>
      '用于需要额外请求头的 Cloudflare 隧道或反向代理。请在输入服务器 URL 之前添加请求头。';

  @override
  String get loginHeaderName => '请求头名称';

  @override
  String get loginHeaderValue => '值';

  @override
  String get loginAddHeader => '添加请求头';

  @override
  String get loginSelfSignedCertificates => '自签名证书';

  @override
  String get loginTrustAllCertificates => '信任所有证书（用于自签名/自定义 CA 配置）';

  @override
  String get loginApiKey => 'API 密钥';

  @override
  String get loginApiKeyDescription =>
      '使用管理员生成的 API 密钥代替用户名/密码。当账号的令牌刷新失败时很有用。';

  @override
  String get loginWaitingForSso => '正在等待单点登录(SSO)...';

  @override
  String get loginRedirectUri => '重定向 URI: audiobookshelf://oauth';

  @override
  String get loginOrSignInManually => '或手动登录';

  @override
  String get loginUsername => '用户名';

  @override
  String get loginUsernameRequired => '请输入用户名';

  @override
  String get loginPassword => '密码';

  @override
  String get loginSignIn => '登录';

  @override
  String loginSignInAs(String username) {
    return '以 $username 登录？';
  }

  @override
  String get loginSignInToServer => '登录到此服务器？';

  @override
  String loginSignedInAs(String username) {
    return '已登录为 $username';
  }

  @override
  String get adminCreateSetupFile => '共享登录';

  @override
  String adminSetupFileDescription(String username) {
    return '为 $username 创建私密登录链接，只能用于 Absorb。';
  }

  @override
  String get adminSetupFileServerUrl => '新用户将使用的服务器 URL';

  @override
  String get adminSetupFileNoteWithHeaders =>
      '将包含专用 API 密钥和您的自定义请求头，以便他们能够连接服务器。请将此链接视同密码。';

  @override
  String get adminSetupFileNote => '将包含一个专用 API 密钥。请将此链接视同密码。';

  @override
  String get adminSetupFileCreate => '创建链接';

  @override
  String get adminSetupFileSaveTitle => '保存设置文件';

  @override
  String get adminSetupFileKeyError => '无法为此用户创建 API 密钥';

  @override
  String adminSetupFileSaved(String username) {
    return '已为 $username 保存设置文件';
  }

  @override
  String adminSetupFileFailed(String error) {
    return '创建登录失败: $error';
  }

  @override
  String get setupLinkShareTitle => '共享登录';

  @override
  String setupLinkShareDescription(String username) {
    return '将这条私密链接发送给他们，或让他们扫描二维码，即可$username 身份登录。';
  }

  @override
  String setupLinkPrivateWarning(String username) {
    return '任何拥有此链接的人都可以以 $username 身份登录。请将其视同密码。';
  }

  @override
  String get setupLinkShare => '共享链接';

  @override
  String get setupLinkCopy => '复制链接';

  @override
  String get setupLinkCopied => '登录链接已复制';

  @override
  String get setupLinkSaveFile => '保存设置文件';

  @override
  String get setupLinkQrError => '此设置链接太大，无法生成二维码。请改为分享链接。';

  @override
  String setupLinkShareSubject(String username) {
    return '$username 的 Absorb 登录';
  }

  @override
  String get setupLinkConfirmTitle => '使用此链接登录？';

  @override
  String setupLinkConfirmBody(String server, String username) {
    return '以 $username 身份登录到 $server？仅在您信任链接的发送者时继续。';
  }

  @override
  String get setupLinkInvalid => '此登录链接无效或不完整';

  @override
  String get setupLinkSigningIn => '正在检查登录链接...';

  @override
  String get loginPasteLink => '粘贴登录链接';

  @override
  String get loginPasteLinkHelp => '粘贴您收到的完整登录链接。请将其视同密码。';

  @override
  String get loginFailed => '登录失败';

  @override
  String get loginSsoFailed => '单点登录失败或已取消';

  @override
  String get loginSsoAuthFailed => '单点登录认证失败，请重试。';

  @override
  String get loginRestoreFromBackup => '从备份恢复';

  @override
  String get loginInvalidBackupFile => '无效的备份文件';

  @override
  String get loginRestoreBackupTitle => '恢复备份？';

  @override
  String loginRestoreBackupWithAccounts(int count) {
    return '这将恢复所有设置和 $count 个已保存的账户。你将自动登录。';
  }

  @override
  String get loginRestoreBackupNoAccounts => '这将恢复所有设置。此备份中不包含任何账户。';

  @override
  String get loginRestore => '恢复';

  @override
  String loginRestoredAndSignedIn(String username) {
    return '已恢复设置并以 $username 身份登录';
  }

  @override
  String get loginSessionExpired => '设置已恢复。会话已过期 - 请登录以继续。';

  @override
  String get loginSettingsRestored => '设置已恢复';

  @override
  String loginRestoreFailed(String error) {
    return '恢复失败: $error';
  }

  @override
  String get loginSavedAccounts => '已保存账户';

  @override
  String get libraryTitle => '媒体库';

  @override
  String get librarySearchBooksHint => '搜索书籍、系列、作者、旁白...';

  @override
  String get librarySearchShowsHint => '搜索播客和单集...';

  @override
  String get libraryTabLibrary => '媒体库';

  @override
  String get libraryTabSeries => '系列';

  @override
  String get libraryTabAuthors => '作者';

  @override
  String get libraryTabNarrators => '旁白';

  @override
  String get libraryNoBooks => '未找到书籍';

  @override
  String get libraryNoUnfinishedBooks => '没有未读完的书籍';

  @override
  String get libraryNoBooksInProgress => '暂无进行中的书籍';

  @override
  String get libraryNoFinishedBooks => '暂无已完成书籍';

  @override
  String get libraryAllBooksStarted => '所有书籍均已开始';

  @override
  String get libraryNoDownloadedBooks => '暂无已下载书籍';

  @override
  String get libraryNoSeriesFound => '未找到系列';

  @override
  String get libraryNoBooksWithEbooks => '暂无包含电子书的书籍';

  @override
  String get libraryNoBooksMissingMetadata => '没有缺少该元数据的书籍';

  @override
  String get libraryNoItemsMatchingFilter => '没有符合此筛选条件的项目';

  @override
  String libraryNoBooksInGenre(String genre) {
    return '\"$genre\" 中没有找到书籍';
  }

  @override
  String libraryNoBooksWithTag(String tag) {
    return '没有标记为「$tag」的书籍';
  }

  @override
  String get libraryClearFilter => '清除筛选';

  @override
  String get libraryNoAuthorsFound => '未找到作者';

  @override
  String get libraryNoNarratorsFound => '未找到旁白';

  @override
  String get libraryNoResults => '未找到结果';

  @override
  String get librarySearchBooks => '书籍';

  @override
  String get librarySearchShows => '播客';

  @override
  String get librarySearchEpisodes => '单集';

  @override
  String get librarySearchSeries => '系列';

  @override
  String get librarySearchAuthors => '作者';

  @override
  String get librarySearchTags => '标签';

  @override
  String get librarySearchGenres => '分类';

  @override
  String librarySeriesCount(int count) {
    return '$count 个系列';
  }

  @override
  String libraryAuthorsCount(int count) {
    return '$count 位作者';
  }

  @override
  String libraryNarratorsCount(int count) {
    return '$count 位旁白';
  }

  @override
  String libraryBooksCount(int loaded, int total) {
    return '已加载 $loaded/$total 本书';
  }

  @override
  String libraryListsCount(int collections, int playlists) {
    return '$collections 个书单，$playlists 个播放列表';
  }

  @override
  String get sort => '排序';

  @override
  String get filter => '筛选';

  @override
  String get filterActive => '筛选 ●';

  @override
  String get name => '名称';

  @override
  String get title => '标题';

  @override
  String get author => '作者';

  @override
  String get dateAdded => '添加日期';

  @override
  String get numberOfBooks => '书籍数量';

  @override
  String get publishedYear => '出版年份';

  @override
  String get duration => '时长';

  @override
  String get random => '随机';

  @override
  String get collapseSeries => '折叠系列';

  @override
  String get notFinished => '未完成';

  @override
  String get inProgress => '正在收听';

  @override
  String get filterFinished => '已听完';

  @override
  String get notStarted => '未开始';

  @override
  String get downloaded => '已下载';

  @override
  String get hasEbook => '含电子书';

  @override
  String get noEbook => '无电子书';

  @override
  String get hasSupplementaryEbook => '有补充电子书';

  @override
  String get noSupplementaryEbook => '无补充电子书';

  @override
  String get noSeries => '无系列';

  @override
  String get publishedDecade => '出版年代';

  @override
  String get tracks => '音轨';

  @override
  String get noTracks => '无音轨';

  @override
  String get singleTrack => '单音轨';

  @override
  String get multipleTracks => '多音轨';

  @override
  String get abridged => '删节版';

  @override
  String get issues => '问题';

  @override
  String get rssFeedOpen => 'RSS 订阅源已打开';

  @override
  String get explicitContent => '敏感内容';

  @override
  String get missingMetadata => '缺失元数据';

  @override
  String get genre => '分类';

  @override
  String get tag => '标签';

  @override
  String get clearFilter => '清除筛选';

  @override
  String get noGenresFound => '未找到分类';

  @override
  String get noTagsFound => '未找到标签';

  @override
  String get asc => '升序';

  @override
  String get desc => '降序';

  @override
  String get fileSize => '文件大小';

  @override
  String get lastUpdated => '最后更新';

  @override
  String get fileCreated => '文件创建时间';

  @override
  String get lastModified => '最后修改时间';

  @override
  String get authorFirstLast => '作者（名 姓）';

  @override
  String get authorLastFirst => '作者（姓, 名）';

  @override
  String get progressSort => '进度';

  @override
  String get dateStarted => '开始日期';

  @override
  String get dateFinished => '完成日期';

  @override
  String get episodeCount => '集数';

  @override
  String get sequence => '系列序号';

  @override
  String get absorbingTitle => '正在收听';

  @override
  String get absorbingStop => '停止';

  @override
  String get absorbingManageQueue => '管理队列';

  @override
  String get absorbingDone => '完成';

  @override
  String get absorbingNoDownloadedEpisodes => '暂无已下载剧集';

  @override
  String get absorbingNoDownloadedBooks => '暂无已下载书籍';

  @override
  String get absorbingNothingPlayingYet => '暂无正在播放的内容';

  @override
  String get absorbingNothingAbsorbingYet => '暂无收听中的内容';

  @override
  String get absorbingDownloadEpisodesToListen => '下载单集以离线收听';

  @override
  String get absorbingDownloadBooksToListen => '下载书籍以离线收听';

  @override
  String get absorbingStartEpisodeFromShows => '从播客标签页开始播放剧集';

  @override
  String get absorbingStartBookFromLibrary => '从媒体库标签页开始播放书籍';

  @override
  String get carModeTitle => '车载模式';

  @override
  String get carModeNoBookLoaded => '未加载书籍';

  @override
  String get carModeBookLabel => '书籍';

  @override
  String get carModeChapterLabel => '章节';

  @override
  String get carModeBookmarkDefault => '书签';

  @override
  String get carModeBookmarkAdded => '已添加书签';

  @override
  String get downloadsTitle => '下载';

  @override
  String get downloadsCancelSelection => '取消选择';

  @override
  String get downloadsSelect => '选择';

  @override
  String get downloadsNoDownloads => '暂无下载';

  @override
  String get downloadsDownloading => '下载中';

  @override
  String get downloadsQueued => '排队中';

  @override
  String get downloadsCompleted => '已完成';

  @override
  String get downloadsWaiting => '等待中...';

  @override
  String get downloadsCancel => '取消';

  @override
  String get downloadsDelete => '删除';

  @override
  String downloadsDeleteCount(int count) {
    return '删除 $count 个下载项？';
  }

  @override
  String get downloadsDeleteContent => '已下载的文件将从本设备中移除。';

  @override
  String downloadsDeletedCount(int count) {
    return '已删除 $count 个下载项';
  }

  @override
  String get downloadsRemoveTitle => '移除下载？';

  @override
  String downloadsRemoveContent(String title) {
    return '从本设备中删除 \"$title\"？';
  }

  @override
  String downloadsRemovedTitle(String title) {
    return '\"$title\" 已移除';
  }

  @override
  String downloadsSelectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get bookmarksTitle => '全部书签';

  @override
  String get bookmarksTabBookmarks => '书签';

  @override
  String get bookmarksTabHighlights => '划线';

  @override
  String get highlightOpenInBook => '在书中打开';

  @override
  String get highlightDeleteAction => '删除划线';

  @override
  String get highlightDeleted => '划线已删除';

  @override
  String highlightsDeleteCount(int count) {
    return '删除 $count 条划线？';
  }

  @override
  String highlightsDeletedCount(int count) {
    return '已删除 $count 条划线';
  }

  @override
  String get quoteShareTitle => '分享引用';

  @override
  String get quoteShareAction => '分享';

  @override
  String get quoteShareFailed => '无法生成引用图片';

  @override
  String get quoteShapePortrait => '竖版';

  @override
  String get quoteShapeSquare => '方形';

  @override
  String get quoteShapeStory => '故事';

  @override
  String get quoteStyleBlur => '模糊';

  @override
  String get quoteStyleDim => '变暗';

  @override
  String get quoteStyleNone => '纯封面';

  @override
  String get quoteTextLight => '浅色文字';

  @override
  String get quoteTextDark => '深色文字';

  @override
  String get quoteFieldTitle => '标题';

  @override
  String get quoteFieldDetail => '详情';

  @override
  String get quoteFieldDetailHint => '作者、章节、页码、谁说的';

  @override
  String highlightsMeta(String chapter, String date) {
    return '$chapter · $date';
  }

  @override
  String get bookmarksCancelSelection => '取消选择';

  @override
  String get bookmarksSortedByNewest => '按最新排序';

  @override
  String get bookmarksSortedByPosition => '按位置排序';

  @override
  String get bookmarksSelect => '选择';

  @override
  String get bookmarksNoBookmarks => '暂无书签';

  @override
  String bookmarksDeleteCount(int count) {
    return '删除 $count 个书签？';
  }

  @override
  String get bookmarksDeleteContent => '此操作无法撤销。';

  @override
  String bookmarksDeletedCount(int count) {
    return '已删除 $count 个书签';
  }

  @override
  String get bookmarksJumpTitle => '跳转到书签？';

  @override
  String bookmarksJumpContent(String title, String position, String bookTitle) {
    return '\"$title\" 位于 $position\n在《$bookTitle》中';
  }

  @override
  String get bookmarksJump => '跳转';

  @override
  String get bookmarksNotConnected => '未连接到服务器';

  @override
  String get bookmarksCouldNotLoad => '无法加载书籍';

  @override
  String bookmarksSelectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get statsTitle => '你的统计';

  @override
  String get statsCouldNotLoad => '无法加载统计数据';

  @override
  String get statsTotalListeningTime => '总收听时长';

  @override
  String get statsHoursUnit => '小时';

  @override
  String get statsMinutesUnit => '分钟';

  @override
  String get statsSecondsUnit => '秒';

  @override
  String statsDaysOfAudio(String days) {
    return '相当于 $days 天的音频';
  }

  @override
  String statsHoursOfAudio(String hours) {
    return '相当于 $hours 小时的音频';
  }

  @override
  String get statsToday => '今日';

  @override
  String get statsThisWeek => '本周';

  @override
  String get statsThisMonth => '本月';

  @override
  String get statsActivity => '活动';

  @override
  String get statsCurrentStreak => '当前连续天数';

  @override
  String get statsBestStreak => '最佳连续天数';

  @override
  String get statsFinished => '已完成';

  @override
  String get statsBooksFinished => '书籍';

  @override
  String get statsEpisodesFinished => '单集';

  @override
  String get statsBooksThisYear => '今年书籍';

  @override
  String get statsEpisodesThisYear => '今年单集';

  @override
  String get statsRemoveFromYearTitle => '从今年中移除';

  @override
  String statsRemoveFromYearWithDate(String date, String title) {
    return '服务器上的完成日期仍将为 $date。这只会将「$title」从您的 Absorb 今年书籍列表中移除。';
  }

  @override
  String statsRemoveFromYearNoDate(String title) {
    return '完成日期仍保留在服务器上。这只会将「$title」从您的 Absorb 今年书籍列表中移除。';
  }

  @override
  String get statsRemovedFromYear => '已从今年中移除';

  @override
  String get statsAddBackToYearTitle => '加回今年';

  @override
  String statsAddBackToYearBody(String title) {
    return '将「$title」加回您的 Absorb 今年书籍列表？';
  }

  @override
  String get statsAddBack => '加回';

  @override
  String get statsAddedBackToYear => '已加回今年';

  @override
  String get statsHiddenFromYear => '已从今年隐藏';

  @override
  String get statsNothingHidden => '没有隐藏的内容';

  @override
  String get settingsCustomizeStats => '自定义统计';

  @override
  String get statsGoalTitle => '收听目标';

  @override
  String get statsGoalOff => '关闭';

  @override
  String get statsGoalDaily => '每日';

  @override
  String get statsGoalWeekly => '每周';

  @override
  String get statsGoalMonthly => '每月';

  @override
  String get statsGoalTarget => '目标';

  @override
  String get statsGoalEnterTitle => '设置目标';

  @override
  String get statsGoalEnterTimeHint => '分钟或 h:mm';

  @override
  String statsBooksShort(int count) {
    return '$count 本书';
  }

  @override
  String get statsBookChallengeTitle => '阅读挑战';

  @override
  String get statsBookChallengeDesc => '今年要读完的书籍';

  @override
  String get statsDailyGoal => '每日目标';

  @override
  String get statsWeeklyGoal => '每周目标';

  @override
  String get statsMonthlyGoal => '每月目标';

  @override
  String statsGoalProgress(String done, String target) {
    return '$done / $target';
  }

  @override
  String statsBookChallengeProgress(int done, int target) {
    return '已完成 $done/$target 本书';
  }

  @override
  String get statsGoalReached => '已达成目标';

  @override
  String get statsChartTitle => '收听图表';

  @override
  String get statsChartBar => '柱状图';

  @override
  String get statsChartLine => '折线图';

  @override
  String get statsChartHeatmap => '热力图';

  @override
  String get statsChartDays7 => '7 天';

  @override
  String get statsChartDays30 => '30天';

  @override
  String get statsLast30Days => '过去 30 天';

  @override
  String get statsThisYearTitle => '今年';

  @override
  String get statsSectionsTitle => '分区';

  @override
  String get statsSectionTimePeriods => '时间段';

  @override
  String get statsHeatmapLess => '更少';

  @override
  String get statsHeatmapMore => '更多';

  @override
  String get statsDayOfWeek => '每周日均';

  @override
  String get statsTimeSavedLabel => '倍速节省的时间';

  @override
  String statsTimeSavedSince(String date) {
    return '自 $date 起';
  }

  @override
  String get statsTimeSavedReset => '重置节省的时间';

  @override
  String get statsTimeSavedResetConfirm => '节省的时间将从今天开始重新计时。';

  @override
  String get statsTimeSavedResetDone => '节省的时间已重置';

  @override
  String statsOnPaceFor(int count) {
    return '按当前进度，今年可读完 $count 本书';
  }

  @override
  String get statsDaysActive => '活跃天数';

  @override
  String get statsDailyAverage => '日均时长';

  @override
  String get statsLast7Days => '过去7天';

  @override
  String get statsMostListened => '收听最多';

  @override
  String get statsRecentSessions => '最近会话';

  @override
  String get appShellHomeTab => '首页';

  @override
  String get appShellLibraryTab => '媒体库';

  @override
  String get appShellAbsorbingTab => '正在收听';

  @override
  String get appShellStatsTab => '统计';

  @override
  String get appShellSettingsTab => '设置';

  @override
  String get appShellDiscoverTab => '发现';

  @override
  String get appShellShowsTab => '节目';

  @override
  String get appShellPodcastsTab => '播客';

  @override
  String get libraryTabEpisodes => '单集';

  @override
  String get filterAllEpisodes => '全部';

  @override
  String get filterUnplayed => '未播放';

  @override
  String get episodeFeedEmpty => '没有符合此筛选条件的单集';

  @override
  String get podcastFilterUpNext => '接下来';

  @override
  String get podcastFilterNew => '最新';

  @override
  String get settingsPodcastTab => '播客标签页';

  @override
  String get settingsPodcastTabDesc => '在底部栏中为某个播客媒体库单独增加一个标签页';

  @override
  String get settingsPodcastTabLibrary => '播客标签页媒体库';

  @override
  String get settingsMergeImpliedByPodcastTab => '启用播客标签页时始终开启';

  @override
  String get settingsEpisodeNotifs => '通知设置';

  @override
  String get settingsEpisodeNotifsDesc => '在后台检查新的播客单集和即将上架的书籍';

  @override
  String get notifIntervalOff => '关闭';

  @override
  String notifIntervalMinutes(int n) {
    return '每 $n 分钟';
  }

  @override
  String get notifIntervalHour => '每小时';

  @override
  String notifIntervalHours(int n) {
    return '每 $n 小时';
  }

  @override
  String get settingsBatteryUnrestricted => '允许不受限制地使用电池';

  @override
  String get settingsBatteryUnrestrictedDesc => '防止系统在某些手机上暂停后台检查';

  @override
  String get appShellPressBackToExit => '再按一次返回键退出';

  @override
  String get settingsTitle => '设置';

  @override
  String get sectionAppearance => '外观';

  @override
  String get languageLabel => '语言';

  @override
  String get languageSystemDefault => '跟随系统';

  @override
  String get languageHelpTranslateInvite => '想帮 Absorb 翻译成你的语言吗？';

  @override
  String get themeLabel => '主题';

  @override
  String get themeDark => '深色';

  @override
  String get themeOled => 'OLED';

  @override
  String get themeLight => '浅色';

  @override
  String get themeAuto => '自动';

  @override
  String get colorSourceLabel => '颜色来源';

  @override
  String get colorSourceCoverDescription => '应用颜色跟随当前播放书籍的封面';

  @override
  String get colorSourceWallpaperDescription => '应用颜色跟随系统壁纸';

  @override
  String get colorSourceWallpaper => '壁纸';

  @override
  String get colorSourceNowPlaying => '正在播放';

  @override
  String get colorSourceDynamic => '动态';

  @override
  String get colorSourceManual => '手动';

  @override
  String get colorSourceManualDescription => '使用您在下方选择的固定应用颜色';

  @override
  String get colorSourceCustom => '自定义';

  @override
  String get useColorEverywhereLabel => '在所有地方使用此颜色';

  @override
  String get useColorEverywhereSubtitle =>
      '同时使用您设置的颜色为书籍详情页和播放器卡片着色，而不是使用每本书的封面颜色';

  @override
  String get flatBackgroundLabel => '纯色背景';

  @override
  String get flatBackgroundSubtitle => '移除背景渐变。深色模式下 OLED 屏幕为纯黑色。';

  @override
  String get einkModeLabel => '电子墨水屏模式';

  @override
  String get einkModeSubtitle => '高对比度黑白显示，无动画，专为电子墨水屏设计';

  @override
  String get einkModeIntroBody =>
      '专为电子墨水屏设计。应用会切换到高对比度的纯黑白外观，动画会被关闭，播放卡片失去背景，实时服务器连接保持关闭以节省电量。播放和进度仍会正常同步。您的显示设置会被保留，关闭此模式时恢复。';

  @override
  String get einkModeIntroConfirm => '开启';

  @override
  String get backgroundIntensityLabel => '背景强度';

  @override
  String get startScreenLabel => '启动画面';

  @override
  String get startScreenSubtitle => '应用启动时打开的标签页';

  @override
  String get startScreenHome => '首页';

  @override
  String get startScreenLibrary => '媒体库';

  @override
  String get startScreenAbsorb => '正在收听';

  @override
  String get startScreenStats => '统计';

  @override
  String get disablePageFade => '禁用页面淡入淡出';

  @override
  String get disablePageFadeOnSubtitle => '页面立即切换';

  @override
  String get disablePageFadeOffSubtitle => '切换标签页时页面淡入淡出';

  @override
  String get rectangleBookCovers => '矩形书籍封面';

  @override
  String get progressTextSize => '进度文字大小';

  @override
  String get rectangleBookCoversOnSubtitle => '封面以 2:3 的书籍比例显示';

  @override
  String get rectangleBookCoversOffSubtitle => '封面为正方形';

  @override
  String get coverSize => '封面大小';

  @override
  String get coverSizeSubtitle => '媒体库网格中每行容纳的封面数量';

  @override
  String get coverSizeSmall => '小';

  @override
  String get coverSizeMedium => '中';

  @override
  String get coverSizeLarge => '大';

  @override
  String get sectionAbsorbingCards => '收听卡片';

  @override
  String get fullScreenPlayer => '全屏播放器';

  @override
  String get fullScreenPlayerOnSubtitle => '开启 - 播放时以全屏方式打开书籍';

  @override
  String get fullScreenPlayerOffSubtitle => '关闭 - 在卡片视图内播放';

  @override
  String get fullBookScrubber => '全书进度条';

  @override
  String get fullBookScrubberOnSubtitle => '开启 - 可拖动滑块跳转至全书任意位置';

  @override
  String get fullBookScrubberOffSubtitle => '关闭 - 仅显示进度条';

  @override
  String get cardScrubbers => '卡片进度条';

  @override
  String get cardScrubbersBoth => '两者';

  @override
  String get cardScrubbersChapter => '章节';

  @override
  String get cardScrubbersLocked => '已锁定';

  @override
  String get cardScrubbersBothSubtitle => '全书和章节进度条均可拖动';

  @override
  String get cardScrubbersChapterSubtitle => '仅章节进度条可拖动';

  @override
  String get cardScrubbersLockedSubtitle => '仅显示进度，不可拖动';

  @override
  String get speedAdjustedTime => '变速后时间';

  @override
  String get speedAdjustedTimeOnSubtitle => '开启 - 剩余时间会根据播放速度变化';

  @override
  String get speedAdjustedTimeOffSubtitle => '关闭 - 显示原始音频时长';

  @override
  String get buttonLayout => '按钮布局';

  @override
  String get buttonLayoutSubtitle => '卡片上操作按钮的排列方式';

  @override
  String get whenAbsorbed => '当收听完成时';

  @override
  String get whenAbsorbedInfoTitle => '当收听完成时';

  @override
  String get whenAbsorbedInfoContent =>
      '控制当您完成一本书或一集后收听卡片的行为。\n\n已完成的卡片会自动从从您的“正在收听”屏幕中移除。';

  @override
  String get whenAbsorbedSubtitle => '听完一本书或或一集后收听卡片的处理方式';

  @override
  String get whenAbsorbedShowOverlay => '显示覆盖层';

  @override
  String get whenAbsorbedAutoRelease => '自动释放';

  @override
  String get mergeLibraries => '合并媒体库';

  @override
  String get mergeLibrariesInfoTitle => '合并媒体库';

  @override
  String get mergeLibrariesInfoContent =>
      '启用后，“正在收听”界面会将您所有媒体库中正在进行的书籍和播客集中显示在一个视图中。禁用时，仅显示您当前所选媒体库中的项目。';

  @override
  String get mergeLibrariesOnSubtitle => '正在收听页面显示来自所有媒体库的项目';

  @override
  String get mergeLibrariesOffSubtitle => '正在收听页面仅显示当前媒体库';

  @override
  String get queueMode => '队列模式';

  @override
  String get queueModeInfoTitle => '队列模式';

  @override
  String get queueModeInfoOff => '关闭';

  @override
  String get queueModeInfoOffDesc => '当前书籍或单集播放完成后停止播放。';

  @override
  String get queueModeInfoManual => '手动队列';

  @override
  String get queueModeInfoManualDesc =>
      '你的收听卡片将作为播放列表使用。当一个播放完成时，会自动播放下一个未完成的卡片。通过书籍或单集详情页的\"添加至正在收听\"按钮添加项目，并在收听界面重新排序。';

  @override
  String get queueModeOff => '关闭';

  @override
  String get queueModeManual => '手动';

  @override
  String get queueModeAuto => '自动';

  @override
  String get queueModePlaylist => '播放列表';

  @override
  String get queueModeCollection => '收藏集';

  @override
  String get queueModeInfoPlaylist => '播放队列';

  @override
  String get queueModeInfoPlaylistDesc => '按所选播放列表的顺序播放，跳过已完成的项目，并在列表结束时停止。';

  @override
  String get queuePlaylistPickerTitle => '选择一个播放列表';

  @override
  String get queuePlaylistNone => '没有选择播放列表';

  @override
  String queuePlaylistActiveLabel(String name) {
    return '播放列表：$name';
  }

  @override
  String get queueModePlaylistHint => '在首页打开一个播放列表，即可启动播放列表队列。';

  @override
  String get exit => '退出';

  @override
  String upNext(String label) {
    return '接下来: $label';
  }

  @override
  String get nothingUpNext => '接下来没有内容';

  @override
  String get showUpNextLabel => '在收听页面显示“接下来”';

  @override
  String get openSeries => '打开系列';

  @override
  String get openPlaylist => '打开播放列表';

  @override
  String get openCollection => '打开收藏集';

  @override
  String get playlistPlayAction => '播放列表';

  @override
  String get playlistAllFinished => '全部听完';

  @override
  String get queueModeBooks => '书籍';

  @override
  String get queueModePodcasts => '播客';

  @override
  String get autoDownloadQueue => '自动下载队列';

  @override
  String get autoDownloadThisSeriesLabel => '自动下载此系列';

  @override
  String get autoDownloadThisShowLabel => '自动下载此播客';

  @override
  String get autoDownloadThisPlaylistLabel => '自动下载此播放列表';

  @override
  String get autoDownloadThisCollectionLabel => '自动下载此收藏集';

  @override
  String autoDownloadQueueOnSubtitle(int count) {
    return '保留接下来 $count 个项目的下载';
  }

  @override
  String get autoDownloadQueueOffSubtitle => '关闭 - 仅手动下载';

  @override
  String get sectionPlayback => '播放';

  @override
  String get sectionMediaControls => '媒体控制';

  @override
  String get defaultSpeed => '默认速度';

  @override
  String get defaultSpeedSubtitle => '新书以此速度开始播放 - 每本书会记住自己的速度';

  @override
  String get skipBack => '快退';

  @override
  String get skipForward => '快进';

  @override
  String get iosLockScreenSkipHint =>
      '锁屏只显示 iOS 有图标的数值（5、10、15、30、45、60、75、90）。其他数值会在按钮上显示 +，但仍按您设置的值快进/快退。';

  @override
  String get longSkipButtons => '长跳按钮';

  @override
  String get longSkipButtonsOnSubtitle => '开启 - 播放器显示第二组更大的跳转按钮';

  @override
  String get longSkipButtonsOffSubtitle => '关闭 - 仅显示常规跳转按钮';

  @override
  String get longSkipBack => '长跳后退';

  @override
  String get longSkipForward => '长跳前进';

  @override
  String get chapterSkipTitle => '跳过片头/片尾';

  @override
  String chapterSkipOnSubtitleFormat(String intro, String outro) {
    return '已开启 - 跳过片头 ${intro}s，跳过片尾 ${outro}s';
  }

  @override
  String get chapterSkipOffSubtitle => '已关闭 - 正常播放章节';

  @override
  String get chapterSkipIntro => '跳过片头（秒）';

  @override
  String get chapterSkipOutro => '跳过片尾（秒）';

  @override
  String get chapterSkipShort => '跳过片头/片尾';

  @override
  String get chapterSkipSheetTitle => '章节跳过';

  @override
  String get chapterSkipPerBookSubtitle => '每一本都会单独记住设置';

  @override
  String get chapterSkipEnabled => '跳过片头片尾';

  @override
  String get coverShapeDefault => '默认';

  @override
  String get coverShapeSquare => '方形';

  @override
  String get coverShapeRectangle => '矩形';

  @override
  String get coverShapeLabel => '封面形状';

  @override
  String get showSubtitles => '显示副标题';

  @override
  String get showSubtitlesOnSubtitle => '副标题显示在媒体库和首页中的书籍标题下方';

  @override
  String get showSubtitlesOffSubtitle => '关闭 - 仅在书籍详情页显示副标题';

  @override
  String get subtitleVisibilityLabel => '副标题';

  @override
  String get subtitleVisibilityDefault => '默认';

  @override
  String get subtitleVisibilityShow => '显示';

  @override
  String get subtitleVisibilityHide => '隐藏';

  @override
  String currentLibrarySettingsTitle(String name) {
    return '当前媒体库: $name';
  }

  @override
  String get currentLibrarySkipOverride => '自定义跳转时间';

  @override
  String get currentLibrarySkipOverrideOnSubtitle => '开启 - 此媒体库使用自己的跳转时间';

  @override
  String get currentLibrarySkipOverrideOffSubtitle => '关闭 - 此媒体库使用全局跳转时间';

  @override
  String get currentLibrarySkipBack => '快退';

  @override
  String get currentLibrarySkipForward => '快进';

  @override
  String get chapterProgressInNotification => '通知中显示章节进度';

  @override
  String get chapterProgressOnSubtitle => '开启 - 锁屏显示章节进度';

  @override
  String get chapterProgressOffSubtitle => '关闭 - 锁屏显示全书进度';

  @override
  String get chapterProgressInNotificationIos => '锁屏和 CarPlay 上的章节进度';

  @override
  String get chapterProgressOnSubtitleIos => '开启 - 锁屏和 CarPlay 显示章节进度';

  @override
  String get speedBookmarkInControls => '媒体控制中的速度和书签';

  @override
  String get speedBookmarkOnSubtitle => '开启 - 通知显示速度和书签；章节跳转保留在 Android Auto 中';

  @override
  String get speedBookmarkOffSubtitle =>
      '关闭 - 通知显示章节跳转；速度和书签保留在 Android Auto 中';

  @override
  String get lockSeekBar => '锁定搜索栏';

  @override
  String get lockSeekBarOnSubtitle => '开启 - 通知、锁屏和车载中的进度条显示进度但不可拖动';

  @override
  String get lockSeekBarOffSubtitle => '关闭 - 可拖动通知、锁屏和车载中的进度条以跳转';

  @override
  String get autoRewindOnResume => '恢复播放时自动倒退';

  @override
  String autoRewindOnSubtitle(String min, String max) {
    return '开启 - 根据暂停时长倒回 $min 秒至 $max 秒';
  }

  @override
  String get autoRewindOffSubtitle => '关闭';

  @override
  String get rewindRange => '倒回范围';

  @override
  String get rewindAfterPausedFor => '暂停后倒回';

  @override
  String get rewindAnyPause => '任何暂停';

  @override
  String get rewindAlwaysLabel => '始终';

  @override
  String get rewindAlwaysDescription => '每次恢复播放都倒回，即使是短暂中断';

  @override
  String rewindAfterDescription(String seconds) {
    return '仅在暂停 $seconds 秒以上时倒回';
  }

  @override
  String get chapterBarrier => '自动倒回不跨越章节';

  @override
  String get chapterBarrierSubtitle => '暂停恢复或新会话倒回时，最多退到当前章节开头，不进入上一章';

  @override
  String get rewindInstant => '立即';

  @override
  String rewindPause(String duration) {
    return '暂停 $duration';
  }

  @override
  String get rewindNoRewind => '不倒回';

  @override
  String rewindSeconds(String seconds) {
    return '倒回 $seconds 秒';
  }

  @override
  String get sectionSleepTimer => '睡眠定时器';

  @override
  String get sleep => '睡眠';

  @override
  String get sleepTimer => '睡眠定时器';

  @override
  String get shakeDuringSleepTimer => '睡眠定时器期间摇一摇';

  @override
  String get shakeOff => '关闭';

  @override
  String get shakeAddTime => '添加时间';

  @override
  String get shakeReset => '重置';

  @override
  String get shakeAdds => '摇一摇添加';

  @override
  String get sleepAddAmount => '添加的时间量';

  @override
  String shakeAddsValue(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get shakeSensitivity => '摇一摇灵敏度';

  @override
  String get shakeSensitivityVeryLow => '非常低';

  @override
  String get shakeSensitivityLow => '低';

  @override
  String get shakeSensitivityMedium => '中';

  @override
  String get shakeSensitivityHigh => '高';

  @override
  String get shakeSensitivityVeryHigh => '非常高';

  @override
  String get buttonDuringSleepTimer => '缓和提醒期间的耳机按钮';

  @override
  String get buttonDuringSleepTimerHint => '在最后的缓和提醒阶段，按一次会重置定时器而非暂停。快速双击仍可跳转。';

  @override
  String get resetTimerOnPause => '暂停时重置定时器';

  @override
  String get resetTimerOnPauseOnSubtitle => '恢复播放时，定时器从完整时长重新开始';

  @override
  String get resetTimerOnPauseOffSubtitle => '定时器从上次停止的位置继续';

  @override
  String get fadeVolumeBeforeSleep => '睡前渐弱音量';

  @override
  String get fadeVolumeOnSubtitle => '在最后30秒逐渐降低音量';

  @override
  String get fadeVolumeOffSubtitle => '定时器结束时立即停止播放';

  @override
  String get autoSleepTimer => '自动睡眠定时器';

  @override
  String autoSleepTimerOnSubtitle(String start, String end, int duration) {
    return '$start - $end - $duration 分钟';
  }

  @override
  String get autoSleepTimerOffSubtitle => '在指定时间段内自动启动睡眠定时器';

  @override
  String get windowStart => '开始时间';

  @override
  String get windowEnd => '结束时间';

  @override
  String get timerDuration => '定时器时长';

  @override
  String get timer => '定时器';

  @override
  String get endOfChapter => '章节结束';

  @override
  String startMinTimer(int minutes) {
    return '启动 $minutes 分钟定时器';
  }

  @override
  String sleepAfterChapters(int count, String label) {
    return '在 $count $label后睡眠';
  }

  @override
  String get addMoreTime => '添加时间';

  @override
  String get cancelTimer => '取消定时器';

  @override
  String chaptersLeftCount(int count) {
    return '剩余 $count 章';
  }

  @override
  String get sectionDownloadsAndStorage => '下载与存储';

  @override
  String get downloadOverWifiOnly => '仅在 Wi-Fi 下下载';

  @override
  String get downloadOverWifiOnSubtitle => '开启 - 禁止使用移动数据下载';

  @override
  String get downloadOverWifiOffSubtitle => '关闭 - 任何网络均可下载';

  @override
  String get autoDownloadOnWifi => 'Wi-Fi 下自动下载';

  @override
  String get autoDownloadOnWifiInfoTitle => 'Wi-Fi 下自动下载';

  @override
  String get autoDownloadOnWifiInfoContent =>
      '当您开始在线播放书籍时，系统会在后台同步下载完整内容，无需手动操作即可实现离线收听。后台下载将严格遵循上方的“下载网络设置”，若您希望在移动网络下也能自动下载，请将其设置为“任意网络”。';

  @override
  String get autoDownloadOnWifiOnSubtitle => '在 Wi-Fi 下开始流式播放时，书籍将在后台下载';

  @override
  String get autoDownloadOnWifiOffSubtitle => '关闭';

  @override
  String get concurrentDownloads => '同时下载数';

  @override
  String get autoDownload => '自动下载';

  @override
  String get autoDownloadSubtitle => '在系列或播客详情页单独启用';

  @override
  String get autoDownloadEnabledFor => '已开启的项目';

  @override
  String get autoDownloadEnabledForNone => '暂无';

  @override
  String get autoDownloadSourceUnnamed => '尚未加载';

  @override
  String get keepNext => '保留接下来';

  @override
  String get keepNextInfoTitle => '保留接下来';

  @override
  String get keepNextInfoContent =>
      '要保留下载的项目数量，包括你当前正在收听的项目。例如，\"保留接下来3个\"意味着当前书籍加上系列或播客中的下2本将保持下载状态。';

  @override
  String get deleteAbsorbedDownloads => '删除已完成的下载';

  @override
  String get deleteAbsorbedDownloadsInfoTitle => '删除已完成的下载';

  @override
  String get deleteAbsorbedDownloadsInfoContent =>
      '启用后，在 Absorb 中听完的已下载书籍或剧集会自动从此设备删除。如果你在网页端或其他设备上听完，保存在此设备上的下载不会被删除。';

  @override
  String get deleteAbsorbedOnSubtitle => '已完成项目将被移除以节省空间';

  @override
  String get deleteAbsorbedOffSubtitle => '关闭 - 保留已完成的下载';

  @override
  String get downloadLocation => '下载位置';

  @override
  String get storageUsed => '已用存储';

  @override
  String storageUsedByDownloads(String size) {
    return '下载已使用 $size';
  }

  @override
  String storageFreeOfTotal(String free, String total) {
    return '总计 $total，可用 $free';
  }

  @override
  String get manageDownloads => '管理下载';

  @override
  String get manageDownloadsSubtitle => '查看、暂停、继续或删除本机下载';

  @override
  String get downloadsPaused => '已暂停';

  @override
  String get downloadsPause => '暂停';

  @override
  String get downloadsResume => '继续';

  @override
  String get downloadsManageTracks => '分集管理';

  @override
  String get downloadsStoredExternally => '存储于外部存储';

  @override
  String get downloadsNoPerTrackSaf => '保存到外部存储的下载不支持单集删除。';

  @override
  String get downloadsTrackDeleteTitle => '删除这一集？';

  @override
  String downloadsTrackDeleteContent(String title) {
    return '要将\"$title\"从本机移除吗？该集的播放将停止。';
  }

  @override
  String downloadsSummary(int count, String size) {
    return '$count 个下载 · $size';
  }

  @override
  String get downloadsSort => '排序';

  @override
  String get downloadsSortTitle => '标题';

  @override
  String get downloadsSortSize => '大小';

  @override
  String get downloadsSortRecent => '最近下载';

  @override
  String get downloadsSearchHint => '搜索下载';

  @override
  String get downloadsNoResults => '没有匹配的下载';

  @override
  String get downloadsResumeAll => '全部继续';

  @override
  String get downloadsDeleteAll => '全部删除';

  @override
  String get downloadsDeleteAllContent => '要将所有已暂停的下载从本机移除吗？';

  @override
  String get downloadsManageFiles => '音频文件管理';

  @override
  String get downloadsPlayFromHere => '从这一集开始播放';

  @override
  String get downloadsGapSkipped => '已删除的集在播放时会跳过';

  @override
  String downloadsDeleteTracksCount(int count) {
    return '删除 $count 集？';
  }

  @override
  String selectRange(int start, int end) {
    return '选集（$start-$end）';
  }

  @override
  String get streamingCache => '流式缓存';

  @override
  String get streamingCacheInfoTitle => '流式缓存';

  @override
  String get streamingCacheInfoContent =>
      '将流式播放的音频缓存到磁盘，以便在快退或重复收听时无需重新下载。缓存会自动管理 - 达到大小限制时，最旧的文件会被移除。这与完全下载的书籍是分开的';

  @override
  String get streamingCacheOff => '关闭';

  @override
  String get streamingCacheOffSubtitle => '关闭 - 音频直接流式播放，不缓存';

  @override
  String streamingCacheOnSubtitle(int size) {
    return '$size MB - 最近流式播放的音频将缓存到磁盘';
  }

  @override
  String get clearCache => '清除缓存';

  @override
  String get streamingCacheCleared => '流式缓存已清除';

  @override
  String get appCache => '进度缓存';

  @override
  String appCacheHint(String size) {
    return '$size 书架、网格、阅读进度和播放会话缓存。使用时会自动重新下载。';
  }

  @override
  String get appCacheConfirm => '要删除所有书架、网格、阅读进度和播放会话缓存吗？它们会在使用时自动重新下载。';

  @override
  String get appCacheCleared => '进度缓存已清除';

  @override
  String get clearCacheHint => '封面、进度、流媒体和残留文件，可分别清理。';

  @override
  String get clearCacheSheetTitle => '清除缓存';

  @override
  String get clearCacheSheetSubtitle => '选择要清理的内容。之后使用时会自动重新生成。';

  @override
  String get cacheCovers => '封面缓存';

  @override
  String get cacheCoversHint => '已下载的书籍、系列、作者封面及桌面组件封面副本。';

  @override
  String get cacheAppDataHint => '书架、网格、阅读进度和播放会话缓存。';

  @override
  String get cacheStreamingHint => '最近流式播放的音频保存在本地，便于即时重播。';

  @override
  String get clearAllCaches => '全部清除';

  @override
  String get clearAllCachesConfirm => '要清除全部缓存吗？它们会在使用时自动重新生成。';

  @override
  String get cacheAllCleared => '全部缓存已清除';

  @override
  String get coverCacheCleared => '封面缓存已清除';

  @override
  String get cacheSystemCacheLabel => '系统缓存';

  @override
  String get cacheSystemDataLabel => '系统数据';

  @override
  String get cacheSystemStatsHint => '安卓系统针对本应用报告的数值。';

  @override
  String get cacheCodeCacheLabel => '代码缓存';

  @override
  String get cacheTilesSumLabel => '所列分类合计';

  @override
  String get cacheExports => '残留缓存';

  @override
  String get cacheExportsHint => '分享卡片、剪辑音频、转录文件、电子书文件、更新包等。';

  @override
  String get exportsCleared => '残留缓存已清除';

  @override
  String get sectionLibrary => '媒体库';

  @override
  String get hideEbookOnlyTitles => '隐藏仅含电子书的标题';

  @override
  String get hideEbookOnlyOnSubtitle => '隐藏没有音频文件的书籍';

  @override
  String get hideEbookOnlyOffSubtitle => '关 - 显示所有媒体库项目';

  @override
  String get showGoodreadsButton => '显示 Goodreads 按钮';

  @override
  String get showGoodreadsOnSubtitle => '书籍详情页显示 Goodreads 的链接';

  @override
  String get showGoodreadsOffSubtitle => '关 - 隐藏 Goodreads 按钮';

  @override
  String get sectionPermissions => '权限';

  @override
  String get notifications => '通知';

  @override
  String get notificationsSubtitle => '用于下载进度和播放控制';

  @override
  String get notificationsAlreadyEnabled => '通知权限已启用';

  @override
  String get unrestrictedBattery => '无限制电池权限';

  @override
  String get unrestrictedBatterySubtitle => '防止 Android 终止后台播放';

  @override
  String get batteryAlreadyUnrestricted => '电池优化已关闭';

  @override
  String get sectionIssuesAndSupport => '问题与支持';

  @override
  String get bugsAndFeatureRequests => '错误报告与功能请求';

  @override
  String get bugsAndFeatureRequestsSubtitle => '在 GitHub 上提交问题';

  @override
  String get joinDiscord => '加入 Discord';

  @override
  String get joinDiscordSubtitle => '社区、支持与更新';

  @override
  String get contact => '联系我们';

  @override
  String get contactSubtitle => '通过邮件发送设备信息';

  @override
  String get enableLogging => '启用日志记录';

  @override
  String get enableLoggingOnSubtitle => '开启 - 日志保存到文件（重启生效）';

  @override
  String get enableLoggingOffSubtitle => '关闭 - 不捕获日志';

  @override
  String get loggingEnabledSnackbar => '日志记录已启用 - 重启应用以开始捕获';

  @override
  String get loggingDisabledSnackbar => '日志记录已禁用 - 重启应用以停止捕获';

  @override
  String get sendLogs => '发送日志';

  @override
  String get sendLogsSubtitle => '以附件形式分享日志文件';

  @override
  String failedToShare(String error) {
    return '分享失败: $error';
  }

  @override
  String get clearLogs => '清除日志';

  @override
  String get logsCleared => '日志已清除';

  @override
  String get clearLogsQuestion => '清除日志？';

  @override
  String get clearLogsContent => '此操作无法撤销。如果之后可能需要，请先发送日志。';

  @override
  String get sectionAdvanced => '高级';

  @override
  String get localServer => '本地服务器';

  @override
  String get localServerInfoTitle => '本地服务器';

  @override
  String get localServerInfoContent =>
      '如果你在家运行 Audiobookshelf 服务器，可以在此设置本地/局域网 URL。Absorb 在检测到您处于家庭网络时会自动切换到更快的本地连接，而在外出时则回退到远程 URL。';

  @override
  String get localServerOnConnectedSubtitle => '已通过本地服务器连接';

  @override
  String get localServerOnRemoteSubtitle => '已启用 - 正在使用远程服务器';

  @override
  String get localServerOffSubtitle => '在家庭 Wi-Fi 下自动切换到局域网服务器';

  @override
  String get localServerUrlLabel => '本地服务器 URL';

  @override
  String get localServerUrlHint => 'http://192.168.1.100:13378';

  @override
  String get localServerUrlSetSnackbar => '本地服务器 URL 已设置 - 当处于家庭网络时将自动连接';

  @override
  String get disableAudioFocus => '禁用音频焦点';

  @override
  String get disableAudioFocusInfoTitle => '音频焦点';

  @override
  String get disableAudioFocusInfoContent =>
      '默认情况下，Android 一次只给一个应用音频“焦点” - 当 Absorb 播放时，其他音频（音乐、视频）会暂停。禁用音频焦点可让 Absorb 与其他应用同时播放。无论此设置如何，来电时始终会暂停播放。';

  @override
  String get disableAudioFocusOnSubtitle => '开启 - 与其他音频同时播放（来电时仍会暂停）';

  @override
  String get disableAudioFocusOffSubtitle => '关闭 - Absorb 播放时其他音频暂停';

  @override
  String get restartRequired => '需要重启';

  @override
  String get restartRequiredContent => '音频焦点更改需要完全重启应用才能生效。立即关闭应用？';

  @override
  String get closeApp => '关闭应用';

  @override
  String get trustAllCertificates => '信任所有证书';

  @override
  String get trustAllCertificatesInfoTitle => '自签名证书';

  @override
  String get mp3IndexSeeking => 'MP3 索引定位';

  @override
  String get mp3IndexSeekingInfoTitle => 'MP3 索引定位';

  @override
  String get mp3IndexSeekingInfoContent =>
      '仅当您的 MP3 文件无法定位到正确位置时才启用此选项。定位不准通常来自可变比特率（VBR）MP3。索引定位会在读取文件时建立精确的时间映射，因此跳转到大型 MP3 的末尾附近可能需要片刻 - 尤其是在流式播放时，因为需要读取文件到该位置。此设置在下次书籍或播客单集开始播放时生效。';

  @override
  String get mp3IndexSeekingOnSubtitle => '开启 - 对 VBR MP3 文件进行精确定位';

  @override
  String get mp3IndexSeekingOffSubtitle => '关闭 - 常规定位';

  @override
  String get trustAllCertificatesInfoContent =>
      '如果你的 Audiobookshelf 服务器使用自签名证书或自定义根 CA，请启用此选项。启用后，Absorb 将跳过所有连接的 TLS 证书验证。仅在您信任当前网络环境时启用。';

  @override
  String get trustAllCertificatesOnSubtitle => '开启 - 接受所有证书';

  @override
  String get trustAllCertificatesOffSubtitle => '关闭 - 仅接受受信任的证书';

  @override
  String get supportTheDev => '支持开发者';

  @override
  String get buyMeACoffee => '请我喝杯咖啡';

  @override
  String appVersionFormat(String version) {
    return 'Absorb v$version';
  }

  @override
  String betaLabel(int number) {
    return 'Beta $number';
  }

  @override
  String appVersionWithServerFormat(String version, String serverVersion) {
    return 'Absorb v$version  -  服务器 $serverVersion';
  }

  @override
  String get backupAndRestore => '备份与恢复';

  @override
  String get backupAndRestoreSubtitle => '将所有设置保存到文件或从文件恢复';

  @override
  String get backUp => '备份';

  @override
  String get restore => '恢复';

  @override
  String get allBookmarks => '所有书签';

  @override
  String get allBookmarksSubtitle => '查看所有书籍的书签';

  @override
  String get switchAccount => '切换账户';

  @override
  String get addAccount => '添加账户';

  @override
  String get logOut => '退出登录';

  @override
  String get includeLoginInfoTitle => '包含登录信息？';

  @override
  String get includeLoginInfoContent =>
      '你是否希望在备份中包含所有已保存账号的登录凭据？\n\n这会让在新设备上恢复变得容易，但文件中将包含您的身份验证令牌。';

  @override
  String get noSettingsOnly => '否，仅设置';

  @override
  String get yesIncludeAccounts => '是，包含账户';

  @override
  String get backupSavedWithAccounts => '备份已保存（包含账户）';

  @override
  String get backupSavedSettingsOnly => '备份已保存（仅设置）';

  @override
  String backupFailed(String error) {
    return '备份失败: $error';
  }

  @override
  String get restoreBackupTitle => '恢复备份？';

  @override
  String get restoreBackupContent => '这将用备份中的值替换您当前的所有设置。';

  @override
  String fromAbsorbVersion(String version) {
    return '来自 Absorb v$version';
  }

  @override
  String restoreAccountsChip(int count) {
    return '$count 个账户';
  }

  @override
  String restoreBookmarksChip(int count) {
    return '$count 本书的书签';
  }

  @override
  String get restoreCustomHeadersChip => '自定义请求头';

  @override
  String get invalidBackupFile => '无效的备份文件';

  @override
  String get settingsRestoredSuccessfully => '设置恢复成功';

  @override
  String restoreFailed(String error) {
    return '恢复失败: $error';
  }

  @override
  String get logOutTitle => '退出登录？';

  @override
  String get logOutContent => '这将使你退出登录。你的下载内容将保留在本设备上。';

  @override
  String get signOut => '退出登录';

  @override
  String get changePasswordTitle => '修改密码';

  @override
  String get changePasswordSubtitle => '安全地更新您的 Audiobookshelf 密码';

  @override
  String get currentPassword => '当前密码';

  @override
  String get newPassword => '新密码';

  @override
  String get confirmNewPassword => '确认新密码';

  @override
  String get passwordChangeEffect =>
      '修改密码会使您的其他 Audiobookshelf 会话退出登录。本设备保持登录。';

  @override
  String get passwordFieldsRequired => '请填写所有密码字段';

  @override
  String get passwordsDoNotMatch => '两次输入的新密码不一致';

  @override
  String get passwordChanged => '密码已修改。其他已登录设备已断开连接。';

  @override
  String get passwordInvalid => '当前密码不正确';

  @override
  String get passwordChangeUnsupported => '该服务器版本不支持在 Absorb 中安全地修改密码';

  @override
  String get passwordChangeFailed => '无法修改您的密码';

  @override
  String get otherUserPasswordResetWarning => '修改此密码会使该用户在所有设备上退出登录。';

  @override
  String get manageSessionsTitle => '已登录设备';

  @override
  String get manageSessionsSubtitle => '查看并移除 Audiobookshelf 会话';

  @override
  String get sessionsCurrent => '当前设备';

  @override
  String get sessionsUnknownDevice => '未知设备';

  @override
  String sessionsLastActive(String date) {
    return '最近活跃于 $date';
  }

  @override
  String get sessionsNone => '无活跃会话';

  @override
  String get sessionsLoadMore => '加载更多';

  @override
  String get sessionsUnsupported => '会话管理需要 Audiobookshelf 2.36 或更高版本。';

  @override
  String get sessionsLoadFailed => '无法加载已登录设备';

  @override
  String get sessionsLegacyNotice => '此登录没有刷新会话，因此 Absorb 无法在列表中识别此设备。';

  @override
  String get sessionsRemove => '让设备退出登录';

  @override
  String get sessionsRemoveTitle => '让此设备退出登录？';

  @override
  String get sessionsRemoveContent => '这会移除其刷新会话。其当前的访问权限可能仍有效，直至该短期令牌过期。';

  @override
  String get sessionsRemoved => '设备已退出登录';

  @override
  String get sessionsRemoveFailed => '无法让该设备退出登录';

  @override
  String get sessionsSignOutAll => '让所有设备退出登录';

  @override
  String get sessionsSignOutAllTitle => '让所有设备退出登录？';

  @override
  String get sessionsSignOutAllContent => '这会移除所有刷新会话，包括本设备的。现有访问令牌在过期前可能仍有效。';

  @override
  String podcastScheduleServerTime(String timeZone) {
    return '更新计划使用服务器时间（$timeZone）';
  }

  @override
  String get podcastScheduleServerTimeUnknown => '更新计划使用服务器时间';

  @override
  String get editServerAddressTitle => '编辑服务器地址';

  @override
  String editServerAddressSubtitle(String username) {
    return '更新 $username 的地址。如果您的服务器地址发生变化，请使用此选项 - 它仍是同一台服务器，只是换了个 URL。您的统计和下载会保留。';
  }

  @override
  String get editServerAddressField => '服务器地址';

  @override
  String get editServerAddressUpdated => '服务器地址已更新';

  @override
  String get editServerAddressFailed => '无法更新服务器地址';

  @override
  String get editServerAddressAction => '编辑服务器地址';

  @override
  String get editServerConnectionTitle => '编辑服务器连接';

  @override
  String editServerConnectionSubtitle(String username) {
    return '更新 $username 的服务器地址和自定义请求头。您的统计和下载会保留。';
  }

  @override
  String get editServerConnectionAction => '编辑服务器连接';

  @override
  String get editServerConnectionUpdated => '服务器连接已更新';

  @override
  String get editServerConnectionFailed => '无法更新服务器连接';

  @override
  String get editCustomHeadersDescription =>
      '用于 Cloudflare 隧道或反向代理。这些请求头仅适用于此已保存的账户。';

  @override
  String get removeAccountAction => '移除账户';

  @override
  String get removeAccountTitle => '移除账户？';

  @override
  String removeAccountContent(String username, String server) {
    return '从已保存账户中移除 $server 上的 $username？\n\n您可以稍后通过重新登录来再次添加。';
  }

  @override
  String get switchAccountTitle => '切换账户？';

  @override
  String switchAccountContent(String username, String server) {
    return '切换到 $server 上的 $username？\n\n你当前的播放将停止，应用将重新加载另一个账户的数据。';
  }

  @override
  String get switchButton => '切换';

  @override
  String get downloadLocationSheetTitle => '下载位置';

  @override
  String get downloadLocationSheetSubtitle => '选择有声读物的保存位置';

  @override
  String get currentLocation => '当前位置';

  @override
  String get existingDownloadsWarning => '现有的下载内容会保留在其当前位置。只有新的下载内容才会使用新路径。';

  @override
  String get chooseFolder => '选择文件夹';

  @override
  String get chooseDownloadFolder => '选择下载文件夹';

  @override
  String get downloadLocationPromptTitle => '选择下载保存位置';

  @override
  String get downloadLocationPromptBody =>
      '下载内容默认保存在应用内部存储中。清理应用数据或卸载应用时,这些下载会被删除。\n\n建议选择手机上的公共文件夹(如「下载」目录)作为默认下载位置,这样即使清除应用数据,下载的文件也会保留。';

  @override
  String get keepDefaultDownloadLocation => '保持默认';

  @override
  String get storagePermissionDenied => '存储权限已被永久拒绝 - 请在应用设置中启用';

  @override
  String get openSettings => '打开设置';

  @override
  String get storagePermissionRequired => '自定义下载位置需要存储权限';

  @override
  String get cannotWriteToFolder => '无法写入该文件夹 - 请选择其他位置或在系统设置中授予文件访问权限';

  @override
  String downloadLocationSetTo(String label) {
    return '下载位置已设置为 $label';
  }

  @override
  String get resetToDefault => '重置为默认';

  @override
  String get resetToDefaultStorage => '重置为默认存储';

  @override
  String legacyDownloadsNotice(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个下载项位于旧的自定义文件夹中，已无法再打开。请重新下载或忽略此提示。',
      one: '1 个下载项位于旧的自定义文件夹中，已无法再打开。请重新下载或忽略此提示。',
    );
    return '$_temp0';
  }

  @override
  String get redownload => '重新下载';

  @override
  String get redownloadStarted => '正在重新下载';

  @override
  String get dismiss => '忽略';

  @override
  String migrateDownloadsToFolder(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '移动 $count 个已有下载到新文件夹？',
      one: '移动 1 个已有下载到新文件夹？',
    );
    return '$_temp0';
  }

  @override
  String migrateDownloadsToInternal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '将 $count 个已有下载移回默认位置？',
      one: '将 1 个已有下载移回默认位置？',
    );
    return '$_temp0';
  }

  @override
  String get keepDownloadsInPlace => '不迁移';

  @override
  String get moveDownloads => '迁移';

  @override
  String get migrateDownloadsTitle => '是否迁移已下载内容？';

  @override
  String get migrateDownloadsHint =>
      '迁移会把已有下载移动到新位置,之后继续在此播放使用。不迁移则保留在原位置,只有新下载使用新位置。';

  @override
  String get migratingDownloads => '正在迁移下载…';

  @override
  String migrateCompleted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已迁移 $count 个下载',
      one: '已迁移 1 个下载',
    );
    return '$_temp0';
  }

  @override
  String get existingDownloadsFoundTitle => '发现已有下载';

  @override
  String existingDownloadsRecognized(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已识别 $count 本之前下载的书',
      one: '已识别 1 本之前下载的书',
    );
    return '$_temp0';
  }

  @override
  String existingDownloadsUnrecognized(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '有 $count 个文件夹含无法识别的音频',
      one: '有 1 个文件夹含无法识别的音频',
    );
    return '$_temp0';
  }

  @override
  String get tipsAndHiddenFeatures => '技巧与隐藏功能';

  @override
  String get tipsSubtitle => '充分利用 Absorb';

  @override
  String get adminTitle => '服务器管理';

  @override
  String get adminTasksTitle => '服务器活动';

  @override
  String adminTasksRunning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个任务正在运行',
      one: '1 个任务正在运行',
    );
    return '$_temp0';
  }

  @override
  String get adminTasksRecent => '最近的服务器活动';

  @override
  String get adminTasksEmpty => '没有正在运行的服务器任务';

  @override
  String adminTaskScanSummary(int added, int updated, int missing) {
    return '新增 $added - 更新 $updated - 缺失 $missing';
  }

  @override
  String get adminServer => '服务器';

  @override
  String get adminVersion => '版本';

  @override
  String get adminUsers => '用户';

  @override
  String get adminOnline => '在线';

  @override
  String get adminBackup => '备份';

  @override
  String get adminPurgeCache => '清除缓存';

  @override
  String get adminManage => '管理';

  @override
  String adminUsersSubtitle(int userCount, int onlineCount) {
    return '$userCount 个账户 - $onlineCount 人在线';
  }

  @override
  String get adminPodcasts => '播客';

  @override
  String get adminPodcastsSubtitle => '搜索、添加和管理节目';

  @override
  String get adminScan => '扫描';

  @override
  String get adminScanning => '正在扫描...';

  @override
  String get adminMatchAll => '匹配全部';

  @override
  String get adminMatching => '正在匹配...';

  @override
  String get adminMatchAllTitle => '匹配所有项目？';

  @override
  String adminMatchAllContent(String name) {
    return '为 $name 中的所有项目匹配元数据？这可能需要一些时间。';
  }

  @override
  String adminScanStarted(String name) {
    return '已开始扫描 $name';
  }

  @override
  String get adminBackupCreated => '备份已创建';

  @override
  String get adminBackupFailed => '备份失败';

  @override
  String get adminCachePurged => '缓存已清除';

  @override
  String get adminRmab => 'ReadMeABook';

  @override
  String get adminRmabSubtitle => '在应用中打开';

  @override
  String get adminRmabAdd => '添加 ReadMeABook 集成';

  @override
  String get adminRmabUrlTitle => 'ReadMeABook URL';

  @override
  String get adminRmabUrlHelp => '粘贴包含登录令牌的 URL。在 RMAB 的管理 -> 用户中生成。';

  @override
  String get adminRmabUrlHint => 'https://rmab.example.com/?token=...';

  @override
  String get adminRmabInvalidUrl => '请输入有效的 http(s) URL';

  @override
  String get adminRmabSaved => '已保存 ReadMeABook';

  @override
  String get adminRmabRemoved => '已移除 ReadMeABook';

  @override
  String get adminRmabReload => '重新加载';

  @override
  String get adminRmabLoadFailed => '无法加载 ReadMeABook，请检查 URL。';

  @override
  String get adminRmabConnected => '已连接';

  @override
  String get adminRmabAskAdmin => '请向您的服务器管理员获取登录 URL';

  @override
  String get adminRmabUrlHelpUser =>
      '请向您的服务器管理员获取登录 URL，管理员可在 RMAB 的管理 -> 用户中生成。';

  @override
  String get adminRmabSettingsInfo =>
      'ReadMeABook 是一个用于请求和下载有声书的自托管服务，需要由您的服务器管理员安装和设置。';

  @override
  String get rmabConfigTitle => '连接 ReadMeABook';

  @override
  String get rmabConfigExplainerAdmin =>
      'ReadMeABook 是一个用于请求有声读物的自托管服务。请在 RMAB 的“管理后台 > 设置 > API”下生成 API 令牌，然后粘贴服务器 URL 和令牌。Absorb 不托管或下载任何内容，它只是向您的服务器发送请求。';

  @override
  String get rmabConfigExplainerUser =>
      'ReadMeABook 是一个用于请求有声读物的自托管服务。请向您的服务器管理员索要 RMAB URL 和 API 令牌。Absorb 不托管或下载任何内容，它只是向您的服务器发送请求。';

  @override
  String get rmabConfigLearnMore => '了解更多关于 ReadMeABook 的信息';

  @override
  String get rmabConfigBaseUrlLabel => 'RMAB 服务器 URL';

  @override
  String get rmabConfigBaseUrlHint => 'https://rmab.example.com';

  @override
  String get rmabConfigTokenLabel => 'API 令牌';

  @override
  String get rmabConfigTokenHint => 'rmab_...';

  @override
  String get rmabConfigLegacyUrlLabel => 'Web UI 登录 URL（可选）';

  @override
  String get rmabConfigLegacyUrlHint => 'https://rmab.example.com/?token=...';

  @override
  String get rmabConfigLegacyUrlHelp =>
      '粘贴您的自动登录 URL，以便“在浏览器视图中打开”能直接登录。留空则使用常规登录。';

  @override
  String get rmabConfigHeadersHelp =>
      '随每次 ReadMeABook 请求发送的额外请求头，适用于 Cloudflare Access 等反向代理。';

  @override
  String get rmabConfigConnect => '连接';

  @override
  String get rmabConfigDisconnect => '断开连接';

  @override
  String get rmabConfigOpenWebView => '在浏览器视图中打开';

  @override
  String rmabConfigConnectedAs(String name) {
    return '已以 $name 身份连接';
  }

  @override
  String get rmabConfigErrorInvalidUrl => '请输入有效的 http(s) URL';

  @override
  String get rmabConfigErrorMissingToken => '请输入您的 API 令牌';

  @override
  String get rmabConfigErrorUnauthorized => '服务器拒绝了令牌';

  @override
  String get rmabConfigErrorForbidden => '此令牌无权执行该操作';

  @override
  String get rmabConfigErrorNetwork => '无法连接 RMAB。请检查 URL。';

  @override
  String get rmabConfigErrorGeneric => '无法连接';

  @override
  String get rmabConfigSavedSnackbar => 'ReadMeABook 已连接';

  @override
  String get rmabConfigDisconnectedSnackbar => 'ReadMeABook 已断开';

  @override
  String get rmabRequestCta => '通过 ReadMeABook 请求';

  @override
  String get rmabSearchHeader => '通过 ReadMeABook 请求';

  @override
  String get rmabSearchHint => '按标题或作者搜索';

  @override
  String get rmabSearchEmpty => '您的 ReadMeABook 服务器上没有匹配项';

  @override
  String get rmabSearchError => '无法搜索 ReadMeABook';

  @override
  String get rmabSearchPrompt => '输入标题或作者进行搜索';

  @override
  String get rmabSearchFooterPrompt => '想找点别的？';

  @override
  String rmabSearchFooterCta(String query) {
    return '在 ReadMeABook 中搜索「$query」';
  }

  @override
  String get rmabBookDetailExplainer =>
      '此请求将通过您的 ReadMeABook 服务器发送，由管理员审核并处理。您可以在 ReadMeABook 磁贴下的“我的请求”中跟踪进度。';

  @override
  String get rmabBookAlreadyAvailable => '已在您的媒体库中';

  @override
  String get rmabBookAlreadyRequested => '已请求';

  @override
  String get rmabRequestSubmitting => '正在提交…';

  @override
  String get rmabRequestSent => '请求已发送';

  @override
  String get rmabRequestErrorAlreadyAvailable => '已在您的媒体库中';

  @override
  String get rmabRequestErrorBeingProcessed => '正在处理中';

  @override
  String get rmabRequestErrorDuplicate => '您已经请求过此内容';

  @override
  String get rmabRequestErrorValidation => '无法发送请求';

  @override
  String get rmabRequestErrorUserNotFound => '令牌用户已不存在。请重新连接 ReadMeABook。';

  @override
  String get rmabRequestErrorIgnored => '此书在您的忽略列表中';

  @override
  String get rmabRequestErrorGeneric => '无法发送请求';

  @override
  String get rmabRequestErrorTokenRejected => '服务器拒绝了令牌。请重新连接 ReadMeABook。';

  @override
  String get rmabMyRequestsTab => '我的请求';

  @override
  String get rmabSetupTab => '设置';

  @override
  String get rmabMyRequestsEmpty => '您还没有请求任何书籍';

  @override
  String get rmabMyRequestsError => '无法加载请求';

  @override
  String get rmabMyRequestsRefresh => '刷新';

  @override
  String get rmabRequestDetailTitle => '请求详情';

  @override
  String get rmabRequestDetailStatus => '状态';

  @override
  String get rmabRequestDetailRequestedOn => '请求时间';

  @override
  String get rmabRequestDetailCompletedOn => '完成时间';

  @override
  String get rmabRequestDetailProgress => '进度';

  @override
  String get rmabStatusActive => '进行中';

  @override
  String get rmabStatusWaiting => '等待中';

  @override
  String get rmabStatusAvailable => '可获取';

  @override
  String get rmabStatusDownloaded => '已下载';

  @override
  String get rmabStatusFailed => '失败';

  @override
  String get rmabStatusCancelled => '已取消';

  @override
  String get rmabStatusDenied => '已拒绝';

  @override
  String get rmabStatusUnknown => '未知';

  @override
  String narratedBy(String narrator) {
    return '朗读者: $narrator';
  }

  @override
  String get onAudible => '在 Audible 上';

  @override
  String percentComplete(String percent) {
    return '已完成 $percent%';
  }

  @override
  String get absorbing => '收听中...';

  @override
  String get absorbAgain => '重新收听';

  @override
  String get absorb => '收听';

  @override
  String get ebookOnlyNoAudio => '仅电子书 - 无音频';

  @override
  String get fullyAbsorbed => '已完成';

  @override
  String get fullyAbsorbAction => '标记为已完成';

  @override
  String get removeFromAbsorbing => '从收听中移除';

  @override
  String get addToAbsorbing => '添加到收听中';

  @override
  String get removedFromAbsorbing => '已从收听中移除';

  @override
  String get addedToAbsorbing => '已添加到收听中';

  @override
  String get removeFromContinueListening => '移出继续收听';

  @override
  String get removedFromContinueListening => '已从“继续收听”中移出';

  @override
  String get removeSeriesFromContinueSeries => '从继续收听中移除';

  @override
  String get removedSeriesFromContinueSeries => '已从继续收听中移除';

  @override
  String get couldNotUpdate => '无法更新，请重试';

  @override
  String get addToPlaylist => '添加到播放列表';

  @override
  String get addToCollection => '添加到收藏集';

  @override
  String get downloadEbook => '下载电子书';

  @override
  String get downloadEbookAgain => '重新下载电子书';

  @override
  String get resetProgress => '重置进度';

  @override
  String get lookupLocalMetadata => '查找本地元数据';

  @override
  String get reLookupLocalMetadata => '重新查找本地元数据';

  @override
  String get clearLocalMetadata => '清除本地元数据';

  @override
  String get searchOnGoodreads => '在 Goodreads 上搜索';

  @override
  String get editServerDetails => '编辑服务器详情';

  @override
  String get encodeTab => '转码';

  @override
  String get codec => '编码器';

  @override
  String get bitrate => '比特率';

  @override
  String get channels => '声道';

  @override
  String get mono => '单声道';

  @override
  String get stereo => '立体声';

  @override
  String get startM4bEncode => '开始 M4B 转码';

  @override
  String get encodeStarted => 'M4B 转码已开始';

  @override
  String get encodeFailed => '无法开始转码';

  @override
  String get encodeFinished => 'M4B 转码已完成';

  @override
  String get currentlyLabel => '当前:';

  @override
  String encodeOutputPathNote(String path) {
    return '转码完成的 M4B 将放入您的有声读物文件夹: $path/';
  }

  @override
  String encodeBackupNote(String itemId) {
    return '您原始音频文件的备份将存储在: /metadata/cache/items/$itemId/。请定期清理项目缓存。';
  }

  @override
  String get encodeTimeNote => '转码最多可能需要 30 分钟。';

  @override
  String get encodeRescanNote => '如果您已禁用文件夹监视器，之后需要重新扫描这本有声读物。';

  @override
  String get aboutSection => '关于';

  @override
  String chaptersCount(int count) {
    return '章节 ($count)';
  }

  @override
  String audioTracksCount(int count) {
    return '音频音轨 ($count)';
  }

  @override
  String libraryFilesCount(int count) {
    return '媒体库文件 ($count)';
  }

  @override
  String get chapters => '章节';

  @override
  String get noChaptersBook => '这本书没有章节';

  @override
  String get noChaptersPodcast => '此播客没有章节';

  @override
  String get failedToLoad => '加载失败';

  @override
  String startedDate(String date) {
    return '开始于 $date';
  }

  @override
  String finishedDate(String date) {
    return '完成于 $date';
  }

  @override
  String andCountMore(int count) {
    return '还有 $count 个';
  }

  @override
  String get markAsFullyAbsorbedQuestion => '标记为已完成？';

  @override
  String get markAsFullyAbsorbedContent => '这将把你的进度设置为100%，如果这本书正在播放则停止播放。';

  @override
  String get markedAsFinishedNiceWork => '已标记为完成 - 干得漂亮！';

  @override
  String get failedToUpdateCheckConnection => '更新失败 - 请检查您的网络连接';

  @override
  String get markAsNotFinishedQuestion => '标记为未完成？';

  @override
  String get markAsNotFinishedContent => '这将清除完成状态，但保留你当前的位置。';

  @override
  String get unmark => '取消标记';

  @override
  String get markedAsNotFinishedBackAtIt => '已标记为未完成 - 继续加油！';

  @override
  String get resetProgressQuestion => '重置进度？';

  @override
  String get resetProgressContent => '这将清除这本书的所有进度并将其重置到开头。此操作无法撤销。';

  @override
  String get progressResetFreshStart => '进度已重置 - 全新开始！';

  @override
  String get clearLocalMetadataQuestion => '清除本地元数据？';

  @override
  String get clearLocalMetadataContent => '这将删除本地存储的元数据并恢复为服务器上的内容。';

  @override
  String get localMetadataCleared => '本地元数据已清除';

  @override
  String get saveEbook => '保存电子书';

  @override
  String get noEbookFileFound => '未找到电子书文件';

  @override
  String get bookmark => '书签';

  @override
  String get bookmarks => '书签';

  @override
  String bookmarksWithCount(int count) {
    return '书签 ($count)';
  }

  @override
  String get playbackSpeed => '播放速度';

  @override
  String get noBookmarksYet => '暂无书签';

  @override
  String get longPressBookmarkHint => '长按书签按钮快速保存';

  @override
  String get addBookmark => '添加书签';

  @override
  String get editBookmark => '编辑书签';

  @override
  String get titleLabel => '标题';

  @override
  String get noteOptionalLabel => '备注（可选）';

  @override
  String get editLayout => '编辑布局';

  @override
  String get inMenu => '在菜单中';

  @override
  String get bookmarkAdded => '已添加书签';

  @override
  String get startPlayingSomethingFirst => '请先开始播放内容';

  @override
  String get playbackHistory => '播放历史';

  @override
  String get historyLocalTab => '历史';

  @override
  String get historyServerTab => '会话';

  @override
  String get historyNoServerSessions => '此项目暂时没有服务器会话';

  @override
  String get historyServerLoadFailed => '无法加载服务器会话';

  @override
  String get clearHistoryTooltip => '清除历史';

  @override
  String get tapEventToJump => '点击事件跳转到对应位置';

  @override
  String get noHistoryYet => '暂无历史';

  @override
  String jumpedToPosition(String position) {
    return '已跳转到 $position';
  }

  @override
  String booksInSeriesCount(int count) {
    return '本系列共 $count 本书';
  }

  @override
  String bookNumber(String number) {
    return '第 $number 本';
  }

  @override
  String downloadRemainingCount(int count) {
    return '剩余下载 ($count)';
  }

  @override
  String get downloadAll => '全部下载';

  @override
  String get markAllNotFinished => '全部标记为未完成';

  @override
  String get markAllFinished => '全部标记为已完成';

  @override
  String get markAllNotFinishedQuestion => '全部标记为未完成？';

  @override
  String get fullyAbsorbSeries => '将系列全部标记为已完成？';

  @override
  String get turnAutoDownloadOff => '关闭自动下载';

  @override
  String get turnAutoDownloadOn => '开启自动下载';

  @override
  String get autoDownloadThisSeries => '自动下载此系列？';

  @override
  String get autoDownloadSeriesContent => '边听边自动下载后续书籍。';

  @override
  String get standalone => '独立';

  @override
  String get episodes => '剧集';

  @override
  String get noEpisodesFound => '未找到剧集';

  @override
  String get markFinished => '标记为完成';

  @override
  String get markUnfinished => '标记为未完成';

  @override
  String get allEpisodes => '全部剧集';

  @override
  String get aboutThisEpisode => '关于本集';

  @override
  String get reversePlayOrder => '倒序播放';

  @override
  String selectedCount(int count) {
    return '已选择 $count 项';
  }

  @override
  String get selectChaptersToDownload => '选择要下载的章节';

  @override
  String startDownloadSelected(int n) {
    return '开始下载（已选 $n）';
  }

  @override
  String get selectAll => '全选';

  @override
  String get deselectAll => '取消全选';

  @override
  String get autoDownloadThisPodcast => '自动下载此播客？';

  @override
  String get autoDownloadPodcastContent => '边听边自动下载后续剧集。';

  @override
  String get download => '下载';

  @override
  String get downloadConfirmTitle => '确认下载';

  @override
  String downloadConfirmContent(String title) {
    return '将“$title”下载到本机？';
  }

  @override
  String get deleteDownload => '删除下载';

  @override
  String get casting => '投屏';

  @override
  String get castingTo => '正在投屏到';

  @override
  String get editDetails => '编辑详情';

  @override
  String get quickMatch => '快速匹配';

  @override
  String get quickMatchNoUpdates => '无需更新';

  @override
  String get custom => '自定义';

  @override
  String get authorOptionalLabel => '作者（可选）';

  @override
  String get noResultsFound => '未找到结果。\n请调整搜索条件或提供商。';

  @override
  String get searchForMetadataAbove => '搜索上方的元数据';

  @override
  String get applyThisMatch => '应用此匹配？';

  @override
  String get metadataUpdated => '元数据已更新';

  @override
  String get failedToUpdateMetadata => '元数据更新失败';

  @override
  String get subtitleLabel => '副标题';

  @override
  String get authorLabel => '作者';

  @override
  String get narratorLabel => '朗读者';

  @override
  String get seriesLabel => '系列';

  @override
  String get addSeries => 'Add series';

  @override
  String get removeSeries => 'Remove series';

  @override
  String get descriptionLabel => '描述';

  @override
  String get publisherLabel => '出版商';

  @override
  String get yearLabel => '年份';

  @override
  String get genresLabel => '分类';

  @override
  String get tagsLabel => '标签';

  @override
  String get commaSeparated => '逗号分隔';

  @override
  String get asinLabel => 'ASIN';

  @override
  String get isbnLabel => 'ISBN';

  @override
  String get coverImage => '封面图片';

  @override
  String get coverRemove => '移除封面';

  @override
  String get coverRemoveConfirm => '移除这本书的封面？将改用生成的标题卡片。';

  @override
  String get coverRemoved => '封面已移除';

  @override
  String get coverRemoveFailed => '无法移除封面';

  @override
  String get coverUrlLabel => '封面 URL';

  @override
  String get coverUrlHint => 'https://...';

  @override
  String get localMetadata => '本地元数据';

  @override
  String get overrideLocalDisplay => '覆盖本地显示';

  @override
  String get metadataSavedLocally => '元数据已本地保存';

  @override
  String get notes => '笔记';

  @override
  String get newNote => '新建笔记';

  @override
  String get editNote => '编辑笔记';

  @override
  String get noNotesYet => '暂无笔记';

  @override
  String get markdownIsSupported => '支持 Markdown';

  @override
  String get markdownMd => 'Markdown (.md)';

  @override
  String get keepsFormattingIntact => '保留完整格式';

  @override
  String get plainTextTxt => '纯文本 (.txt)';

  @override
  String get simpleTextNoFormatting => '简单文本，无格式';

  @override
  String get untitledNote => '无标题笔记';

  @override
  String get titleHint => '标题';

  @override
  String get noteBodyHint => '写下你的笔记...（支持 Markdown）';

  @override
  String get nothingToPreview => '暂无预览内容';

  @override
  String get audioEnhancements => '音频增强';

  @override
  String get presets => '预设';

  @override
  String get equalizer => '均衡器';

  @override
  String get effects => '效果';

  @override
  String get bassBoost => '低音增强';

  @override
  String get surround => '环绕声';

  @override
  String get loudness => '响度';

  @override
  String get monoAudio => '单声道音频';

  @override
  String get skipSilence => '跳过静音';

  @override
  String get resetAll => '全部重置';

  @override
  String get collectionNotFound => '未找到收藏集';

  @override
  String get deleteCollection => '删除收藏集';

  @override
  String get deleteCollectionContent => '你确定要删除此收藏集吗？';

  @override
  String get deleteCollectionFailed => '无法删除收藏集';

  @override
  String get deletePermissionRequired => '需要删除权限。请让 root 管理员授予您删除权限。';

  @override
  String get deleteFilesCheckbox => '同时删除服务器上的文件';

  @override
  String get deleteFilesCheckedHint => '文件将从服务器中永久删除。';

  @override
  String get deleteFilesUncheckedHint => '文件保留在服务器上，因此下次媒体库扫描可能会重新添加此内容。';

  @override
  String get deleteFromServerAction => '从服务器删除';

  @override
  String get deleteFromServerTitle => '从服务器删除';

  @override
  String deleteFromServerContent(String title) {
    return '从 Audiobookshelf 中删除「$title」？';
  }

  @override
  String deletedFromServer(String title) {
    return '已删除「$title」';
  }

  @override
  String get deleteFromServerFailed => '无法删除。请检查服务器日志。';

  @override
  String get playlistNotFound => '未找到播放列表';

  @override
  String get deletePlaylist => '删除播放列表';

  @override
  String get deletePlaylistContent => '你确定要删除此播放列表吗？';

  @override
  String get newPlaylist => '新建播放列表';

  @override
  String get playlistNameHint => '播放列表名称';

  @override
  String addedToName(String name) {
    return '已添加到 \"$name\"';
  }

  @override
  String get failedToAdd => '添加失败';

  @override
  String get newCollection => '新建收藏集';

  @override
  String get collectionNameHint => '收藏集名称';

  @override
  String get castToDevice => '投屏到设备';

  @override
  String get searchingForCastDevices => '正在搜索投屏设备...';

  @override
  String get castDevice => '投屏设备';

  @override
  String get stopCasting => '停止投屏';

  @override
  String get disconnect => '断开连接';

  @override
  String get audioOutput => '音频输出';

  @override
  String get noOutputDevicesFound => '未找到输出设备';

  @override
  String get welcomeToAbsorb => '欢迎使用 Absorb';

  @override
  String get welcomeTagline => '一个 Audiobookshelf 客户端。';

  @override
  String get welcomeAbsorbingTitle => '正在收听';

  @override
  String get welcomeAbsorbingIntro => '我们用 \"absorb\" 代替 \"播放\" 和 \"收听\"。';

  @override
  String get welcomeAbsorbingTabBullet => '正在收听标签页 - 你当前正在收听的内容';

  @override
  String get welcomeAbsorbButtonBullet => 'Absorb 按钮 - 开始播放';

  @override
  String get welcomeFullyAbsorbBullet => 'Fully Absorb - 标记为已完成';

  @override
  String get welcomeGettingAroundTitle => '界面操作';

  @override
  String get welcomeGettingAroundBody =>
      '点击任意封面打开详情。继续收听卡片不一样 - 点击立即播放，长按打开详情。';

  @override
  String get welcomeMakeItYoursTitle => '个性化设置';

  @override
  String get welcomeMakeItYoursBody =>
      '在设置中自定义 Absorb 以符合你的喜好。其中的「技巧与隐藏功能」区块值得一看。';

  @override
  String get getStarted => '开始使用';

  @override
  String get showMore => '显示更多';

  @override
  String get showLess => '显示更少';

  @override
  String get readMore => '阅读更多';

  @override
  String get removeDownloadQuestion => '移除下载？';

  @override
  String get removeDownloadContent => '这将从你的设备中移除。';

  @override
  String get downloadRemoved => '下载已移除';

  @override
  String get finished => '已完成';

  @override
  String get saved => '已保存';

  @override
  String coverSavedCount(int saved, int total) {
    return '已保存 $saved/$total';
  }

  @override
  String downloadedChaptersTitle(int saved, int total) {
    return '已下载 $saved/$total 章';
  }

  @override
  String get downloadedAddMore => '下载章节';

  @override
  String get downloadedSelect => '多选';

  @override
  String get downloadedDone => '完成';

  @override
  String get downloadedTapHint => '点击章节可播放；多选后可批量移除';

  @override
  String removeSelectedChapters(int count) {
    return '移除所选 ($count)';
  }

  @override
  String get downloadedRemove => '移除下载';

  @override
  String get selectLibrary => '选择媒体库';

  @override
  String get switchLibraryTooltip => '切换媒体库';

  @override
  String get refreshTooltip => '刷新';

  @override
  String get noBooksFound => '未找到书籍';

  @override
  String get userFallback => '用户';

  @override
  String get rootAdmin => '超级管理员';

  @override
  String get admin => '管理员';

  @override
  String get serverAdmin => '服务器管理员';

  @override
  String get serverAdminSubtitle => '管理用户、媒体库和服务器设置';

  @override
  String serverUpdateAvailable(String version) {
    return '服务器有可用更新 $version';
  }

  @override
  String get justNow => '刚刚';

  @override
  String minutesAgo(int count) {
    return '$count 分钟前';
  }

  @override
  String hoursAgo(int count) {
    return '$count 小时前';
  }

  @override
  String daysAgo(int count) {
    return '$count 天前';
  }

  @override
  String get audible => 'Audible';

  @override
  String get iTunes => 'iTunes';

  @override
  String get openLibrary => '打开媒体库';

  @override
  String get root => 'Root';

  @override
  String get coverPlayPause => '点击封面播放/暂停';

  @override
  String get coverPlayPauseOnSubtitle => '开启 - 点击封面播放/暂停';

  @override
  String get coverPlayPauseOffSubtitle => '关闭 - 使用控制栏中的播放/暂停按钮';

  @override
  String get cardBackground => '卡片背景';

  @override
  String get cardBackgroundBlurred => '模糊';

  @override
  String get cardBackgroundGradient => '渐变';

  @override
  String get queueModeMergedSubtitle => '可选择停止播放、手动队列，或自动播放下一项';

  @override
  String get queueModeSeriesLabel => '系列';

  @override
  String get queueModeShowLabel => '节目';

  @override
  String get queueModeInfoSeries => '系列';

  @override
  String get queueModeInfoSeriesDesc => '自动播放同系列的下一本书，或播客节目的下一集。';

  @override
  String get resetButtonGridQuestion => '确认重置按钮布局？';

  @override
  String get resetButtonGridContent => '这将恢复默认的按钮布局、顺序和开关设置。';

  @override
  String get reset => '重置';

  @override
  String get buttonGridReset => '按钮网格已重置';

  @override
  String get resetButtonGrid => '重置按钮布局';

  @override
  String get chapterBarrierOnRewind => '快退不跨越章节';

  @override
  String get chapterBarrierInfoTitle => '章节边界';

  @override
  String get chapterBarrierInfoContent =>
      '快退时，播放将跳到当前章节的开头，而不是跨越到上一章。\n\n如需回到上一章，请使用“上一章”按钮。';

  @override
  String get chapterBarrierOnRewindOnSubtitle => '开启 - 快退最多退到当前章节开头，不进入上一章';

  @override
  String get chapterBarrierOnRewindOffSubtitle => '关闭 - 快退可跨越到上一章';

  @override
  String get prevChapterJumpBehavior => '上一章跳章方式';

  @override
  String get prevChapterJumpRestartSubtitle => '关闭 - 仅回到当前章节开头';

  @override
  String get prevChapterJumpDirectSubtitle => '开启 - 直接跳到上一章';

  @override
  String get chaptersConfirmJump => '章节跳转确认';

  @override
  String get chaptersConfirmJumpOnSubtitle => '开启 - 仅在未播放本书时询问';

  @override
  String get chaptersConfirmJumpOffSubtitle => '关闭 - 每次跳转前都询问';

  @override
  String autoRewindOnSubtitleFormat(String min, String max) {
    return '开启 - 根据暂停时长倒回 $min 秒至 $max 秒';
  }

  @override
  String get rewindOnSessionStart => '会话开始时倒回';

  @override
  String get rewindOnSessionStartInfoContent =>
      '常规自动倒回会在活动会话中从暂停恢复时触发。此设置会在开始全新会话时额外倒回 - 例如应用被关闭、播放被停止，或您重新打开应用时。\n\n启用后，每次新会话开始播放时都会按最大倒回量倒回，以便您重新听到上次听到的位置。';

  @override
  String rewindOnSessionStartOnSubtitle(String seconds) {
    return '开启 - 新会话开始时倒回 $seconds 秒';
  }

  @override
  String rewindActivationDelayValue(String seconds) {
    return '$seconds 秒以上';
  }

  @override
  String rewindRangeValue(String min, String max) {
    return '$min 秒 – $max 秒';
  }

  @override
  String rewindSecondsPause(String seconds) {
    return '暂停 $seconds 秒';
  }

  @override
  String rewindMinPause(String minutes) {
    return '暂停 $minutes 分钟';
  }

  @override
  String rewindHrPause(String hours) {
    return '暂停 $hours 小时';
  }

  @override
  String get rewindOneHrPause => '暂停 1 小时';

  @override
  String speedValue(String speed) {
    return '${speed}x';
  }

  @override
  String secondsValue(String seconds) {
    return '$seconds 秒';
  }

  @override
  String minutesValue(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get chimeBeforeSleep => '睡前提示音';

  @override
  String get chimeBeforeSleepOnSubtitle => '在定时器即将结束时播放轻柔的提示铃声';

  @override
  String get chimeBeforeSleepOffSubtitle => '睡前无提示音';

  @override
  String get windDownDuration => '缓和提醒时长';

  @override
  String windDownDurationSubtitle(int seconds) {
    return '定时结束$seconds 秒前开始淡出并提示';
  }

  @override
  String fadeVolumeOnSubtitleDynamic(int seconds) {
    return '在最后 $seconds 秒内逐渐降低音量';
  }

  @override
  String autoSleepTimerEnabledSubtitle(
    String start,
    String end,
    String duration,
  ) {
    return '$start – $end · $duration';
  }

  @override
  String get endOfChapterShort => '章节结束';

  @override
  String get endOfChapterOnSubtitle => '在当前章节结束时停止播放';

  @override
  String get endOfChapterOffSubtitle => '使用睡眠定时器';

  @override
  String get showExplicitBadge => '显示敏感内容标记';

  @override
  String get showExplicitBadgeOnSubtitle => '敏感内容会显示 “E” 标记';

  @override
  String get showExplicitBadgeOffSubtitle => '关闭 - 隐藏敏感内容标记';

  @override
  String get finishedBadgeMode => '已完成标记';

  @override
  String get finishedBadgeModeSubtitle => '在封面显示已完成勾选：带文字、仅图标或关闭。';

  @override
  String get finishedBadgeModeText => '带文字';

  @override
  String get finishedBadgeModeIcon => '仅图标';

  @override
  String get finishedBadgeModeOff => '关闭';

  @override
  String get libraryFallback => '媒体库';

  @override
  String get preReleaseUpdatesInfoTitle => '预发布更新';

  @override
  String get preReleaseUpdatesInfoContent =>
      '启用后，更新检查器还会通知您 GitHub 上的 alpha 和预发布版本。它们可能不太稳定，但包含最新的功能和修复。';

  @override
  String get includePreReleases => '包含预发布版本';

  @override
  String get includePreReleasesOnSubtitle => '开启 - 检查 alpha 和预发布版本';

  @override
  String get includePreReleasesOffSubtitle => '关闭 - 仅稳定版';

  @override
  String get setTooltip => '设置';

  @override
  String get saveAbsorbBackup => '保存 Absorb 备份';

  @override
  String get checkForUpdate => '检查更新';

  @override
  String get onLatestVersion => '您已是最新版本';

  @override
  String get updateCheckFailed => '无法检查更新';

  @override
  String get updateAvailable => '有可用更新';

  @override
  String get preReleaseAvailable => '有预发布版本可用';

  @override
  String updateDialogContent(String kind, String latest, String current) {
    return '有新的 Absorb $kind 可用: $latest\n\n您当前使用的是 $current。';
  }

  @override
  String get updateKindPreRelease => '预发布';

  @override
  String get updateKindVersion => '版本';

  @override
  String get downloadButton => '下载';

  @override
  String get updateDownloading => '正在下载更新...';

  @override
  String get updateInstallPermissionDenied =>
      '安装权限被拒绝。请在系统设置中为 Absorb 启用“安装未知应用”。';

  @override
  String get updateOpeningInBrowser => '应用内更新失败，正在打开浏览器';

  @override
  String get sendToEreader => '发送到 E-Reader';

  @override
  String sendingToEreader(String device) {
    return '正在发送到 $device...';
  }

  @override
  String sendToEreaderSuccess(String device) {
    return '已发送到 $device';
  }

  @override
  String get sendToEreaderFailed => '无法发送电子书';

  @override
  String get pickEreaderDevice => '选择设备';

  @override
  String get adminEmail => '邮件';

  @override
  String get adminEmailSubtitle => 'SMTP 和电子阅读器设备';

  @override
  String get smtpSection => 'SMTP';

  @override
  String get smtpSetupGuide => '设置指南';

  @override
  String get smtpHost => '主机';

  @override
  String get smtpPort => '端口';

  @override
  String get smtpSecure => '加密';

  @override
  String get smtpRejectUnauthorized => '拒绝未经授权的 TLS';

  @override
  String get smtpUser => '用户名';

  @override
  String get smtpPass => '密码';

  @override
  String get smtpFromAddress => '发件地址';

  @override
  String get smtpTestAddress => '测试地址';

  @override
  String get smtpSendTest => '发送测试';

  @override
  String get smtpSaveSettings => '保存';

  @override
  String get smtpSaved => '邮件设置已保存';

  @override
  String get smtpSaveFailed => '无法保存邮件设置';

  @override
  String get smtpTestSent => '测试邮件已发送';

  @override
  String get smtpTestFailed => '测试邮件发送失败';

  @override
  String get ereaderDevicesTitle => '电子阅读器设备';

  @override
  String get ereaderDevicesEmpty => '还没有设备。请在下方添加一个。';

  @override
  String get addEreaderDevice => '添加设备';

  @override
  String get editEreaderDevice => '编辑设备';

  @override
  String get deleteEreaderDevice => '删除';

  @override
  String get ereaderDeviceName => '名称';

  @override
  String get ereaderDeviceEmail => '邮箱';

  @override
  String get ereaderAvailability => '谁可以使用此设备';

  @override
  String get ereaderAvailAdminOrUp => '仅限管理员';

  @override
  String get ereaderAvailUserOrUp => '所有用户';

  @override
  String get ereaderAvailGuestOrUp => '所有人';

  @override
  String get ereaderAvailSpecificUsers => '指定用户';

  @override
  String ereaderSpecificUsersN(int count) {
    return '指定用户（$count）';
  }

  @override
  String get ereaderDevicesSaved => '设备已保存';

  @override
  String get ereaderDevicesSaveFailed => '无法保存设备';

  @override
  String libraryCountOne(int count) {
    return '$count 个媒体库';
  }

  @override
  String libraryCountOther(int count) {
    return '$count 个媒体库';
  }

  @override
  String serverVersionLabel(String version) {
    return '服务器 $version';
  }

  @override
  String appVersionServerSuffix(String version) {
    return ' · 服务器 $version';
  }

  @override
  String backupDateFormat(int month, int day, int year) {
    return '$month/$day/$year';
  }

  @override
  String get backupDetailsSeparator => ' · ';

  @override
  String get bookmarksSortedByPositionReversed => '按位置排序（倒序）';

  @override
  String bookmarksJumpShortContent(String title, String position) {
    return '「$title」位于 $position';
  }

  @override
  String get deleteBookmarkQuestion => '删除书签？';

  @override
  String get cardIconsOnlyChip => '仅图标';

  @override
  String get cardMoreInGridChip => '更多';

  @override
  String get cardLayoutHidden => '已隐藏';

  @override
  String get speed => '速度';

  @override
  String get details => '详情';

  @override
  String get episodeDetailsLabel => '单集详情';

  @override
  String get bookDetailsLabel => '书籍详情';

  @override
  String get equalizerShort => '均衡器';

  @override
  String get equalizerLabel => '音频增强';

  @override
  String get cast => '投屏';

  @override
  String castingToDevice(String device) {
    return '正在投屏到 $device';
  }

  @override
  String castToDeviceNamed(String device) {
    return '投屏到 $device';
  }

  @override
  String get historyShort => '历史';

  @override
  String atPosition(String position) {
    return '位于 $position';
  }

  @override
  String chaptersChip(int count) {
    return '$count 个章节';
  }

  @override
  String chapterNumber(int number) {
    return '第 $number 章';
  }

  @override
  String kbpsValue(int value) {
    return '$value kbps';
  }

  @override
  String get resetMayNotHaveSynced => '重置可能尚未同步 - 请检查您的服务器';

  @override
  String failedToDownloadEbook(int code) {
    return '电子书下载失败（$code）';
  }

  @override
  String get serverReturnedErrorPage => '服务器返回了错误页面，而不是电子书文件';

  @override
  String ebookSaved(String filename) {
    return '已保存: $filename';
  }

  @override
  String errorSavingEbook(String error) {
    return '保存电子书出错: $error';
  }

  @override
  String failedToSaveError(String error) {
    return '保存失败: $error';
  }

  @override
  String get adminBackupsLabel => '备份';

  @override
  String get adminListeningNow => '正在收听';

  @override
  String get adminLibraries => '媒体库';

  @override
  String get adminLibraryShows => '个节目';

  @override
  String get adminLibraryBooks => '本书';

  @override
  String get adminLibraryFolders => '个文件夹';

  @override
  String get adminLibrarySize => '大小';

  @override
  String get adminLibraryDuration => '时长';

  @override
  String adminLibraryIssues(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个缺失或无效的项目',
      one: '1 个缺失或无效的项目',
    );
    return '$_temp0';
  }

  @override
  String get adminLibraryReview => '检查';

  @override
  String get adminMissingTitle => '缺失项目';

  @override
  String adminMissingSubtitle(String library) {
    return '$library 中文件缺失或无法读取的条目';
  }

  @override
  String get adminMissingNone => '没有缺失或无效的项目';

  @override
  String get adminMissingBadge => '缺失';

  @override
  String get adminInvalidBadge => '无效';

  @override
  String get adminMissingDeleteTitle => '移除条目';

  @override
  String adminMissingDeleteOneContent(String title) {
    return '从 Audiobookshelf 中移除「$title」？';
  }

  @override
  String adminMissingDeleteManyContent(int count) {
    return '从 Audiobookshelf 中移除 $count 个条目？';
  }

  @override
  String adminMissingDeleteCount(int count) {
    return '删除 $count';
  }

  @override
  String adminMissingRemovedOne(String title) {
    return '已移除 $title';
  }

  @override
  String adminMissingRemovedMany(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已移除 $count 个条目',
      one: '已移除 1 个条目',
    );
    return '$_temp0';
  }

  @override
  String get adminMissingDeleteFailed => '无法删除条目';

  @override
  String get adminMatchAction => '匹配';

  @override
  String adminMatchingStarted(String name) {
    return '已开始为 $name 匹配';
  }

  @override
  String get adminMatchFailed => '失败';

  @override
  String adminScanFailed(String name) {
    return '扫描 $name 失败';
  }

  @override
  String get adminPurgeCacheFailed => '失败';

  @override
  String get adminUsersRootBadge => 'root';

  @override
  String get adminUsersAdminBadge => '管理员';

  @override
  String get adminUsersDisabledBadge => '已禁用';

  @override
  String get adminUsersEditUserTooltip => '编辑用户';

  @override
  String get adminUsersOnlineNow => '当前在线';

  @override
  String adminUsersLastSeen(String time) {
    return '最后活跃于 $time';
  }

  @override
  String get adminUsersNever => '从未';

  @override
  String get adminUsersTotal => '总计';

  @override
  String get adminUsersNoReadingActivity => '无收听活动';

  @override
  String get adminUsersLoadingDots => '加载中...';

  @override
  String get adminUsersLoadMoreSessions => '加载更多会话';

  @override
  String get adminUsersNoRecentSessions => '无最近会话';

  @override
  String get adminUsersLibraryProgress => '媒体库进度';

  @override
  String adminUsersLoadMoreRemaining(int count) {
    return '加载更多（还剩 $count 个）';
  }

  @override
  String adminUsersMonthsAgo(int count) {
    return '$count 个月前';
  }

  @override
  String get adminUsersNewUser => '新用户';

  @override
  String get adminUsersEditUser => '编辑用户';

  @override
  String get adminUsersUsername => '用户名';

  @override
  String get adminUsersEnterUsername => '输入用户名';

  @override
  String get adminUsersPassword => '密码';

  @override
  String get adminUsersNewPassword => '新密码';

  @override
  String get adminUsersEnterPassword => '输入密码';

  @override
  String get adminUsersLeaveBlankToKeep => '留空则保持当前';

  @override
  String get adminUsersAccountType => '账户类型';

  @override
  String get adminUsersTypeGuest => '访客';

  @override
  String get adminUsersTypeUser => '用户';

  @override
  String get adminUsersTypeAdmin => '管理员';

  @override
  String get adminUsersStatus => '状态';

  @override
  String get adminUsersAccountActive => '账户启用';

  @override
  String get adminUsersAccountActiveSub => '被禁用的账户无法登录';

  @override
  String get adminUsersLocked => '已锁定';

  @override
  String get adminUsersLockedSub => '阻止修改密码';

  @override
  String get adminUsersPermissions => '权限';

  @override
  String get adminUsersPermDownload => '下载';

  @override
  String get adminUsersPermUpdate => '更新';

  @override
  String get adminUsersPermUpdateSub => '编辑元数据和媒体库项目';

  @override
  String get adminUsersPermDelete => '删除';

  @override
  String get adminUsersPermUpload => '上传';

  @override
  String get adminUsersPermExplicit => '敏感内容';

  @override
  String get adminUsersLibraryAccess => '媒体库访问权限';

  @override
  String get adminUsersAccessAllLibraries => '访问所有媒体库';

  @override
  String get adminUsersCreateUser => '创建用户';

  @override
  String get adminUsersSaveChanges => '保存更改';

  @override
  String get adminUsersUsernameRequired => '必须填写用户名';

  @override
  String get adminUsersPasswordRequired => '必须填写密码';

  @override
  String get adminUsersUserCreated => '用户已创建';

  @override
  String get adminUsersUserUpdated => '用户已更新';

  @override
  String get adminUsersFailedCreate => '无法创建用户';

  @override
  String get adminUsersFailedUpdate => '无法更新用户';

  @override
  String get adminUsersThisUser => '此用户';

  @override
  String get adminUsersDeleteUserTitle => '删除用户？';

  @override
  String adminUsersDeleteUserContent(String name) {
    return '永久删除 $name？';
  }

  @override
  String adminUsersUserDeleted(String name) {
    return '已删除 $name';
  }

  @override
  String get adminUsersFailedDelete => '无法删除用户';

  @override
  String get adminUsersUnlinkOpenId => '解除 OpenID 绑定';

  @override
  String get adminUsersUnlinkOpenIdTitle => '解除 OpenID 绑定？';

  @override
  String adminUsersUnlinkOpenIdContent(String name) {
    return '移除 $name 的 OpenID 连接？他们需要再次使用 OpenID 登录才能重新绑定。';
  }

  @override
  String get adminUsersOpenIdUnlinked => 'OpenID 已解除绑定';

  @override
  String get adminUsersFailedUnlinkOpenId => '无法解除 OpenID 绑定';

  @override
  String adminUsersByAuthor(String author) {
    return '作者 $author';
  }

  @override
  String get adminUsersListened => '已收听';

  @override
  String get adminUsersStartedAtPosition => '开始位置';

  @override
  String get adminUsersEndedAtPosition => '结束位置';

  @override
  String get adminUsersTotalDuration => '总时长';

  @override
  String get adminUsersStarted => '开始';

  @override
  String get adminUsersUpdated => '更新';

  @override
  String get adminUsersClient => '客户端';

  @override
  String get adminUsersDevice => '设备';

  @override
  String get adminUsersOs => '系统';

  @override
  String get adminUsersPlayMethod => '播放方式';

  @override
  String get adminUsersPlayDirect => '直接播放';

  @override
  String get adminUsersPlayDirectStream => '直接流式播放';

  @override
  String get adminUsersPlayTranscode => '转码';

  @override
  String get adminUsersPlayLocal => '本地';

  @override
  String get adminPodcastsCheckNewEpisodesTitle => '检查新单集';

  @override
  String get adminPodcastsCheckNewEpisodesContent =>
      '这将检查所有播客的 RSS 订阅源，并下载找到的任何新单集（如果已启用自动下载）。';

  @override
  String get adminPodcastsCheckNewEpisodesSubtitle => '扫描 RSS 订阅源并下载新单集';

  @override
  String get adminPodcastsCheck => '检查';

  @override
  String get adminPodcastsCheckingForNew => '正在检查新单集…';

  @override
  String get adminPodcastsCheckingForNewDots => '正在检查新单集...';

  @override
  String get adminPodcastsFailedCheckEpisodes => '检查单集失败';

  @override
  String get adminPodcastsCheckFeedsTooltip => '检查订阅源中是否有新单集';

  @override
  String get adminPodcastsNoPodcastsYet => '还没有播客';

  @override
  String get adminPodcastsTapPlusHint => '点击 + 搜索并添加节目';

  @override
  String adminPodcastsEpisodesCount(int count) {
    return '$count 个单集';
  }

  @override
  String get adminPodcastsAddPodcast => '添加播客';

  @override
  String get adminPodcastsCouldNotFindFeed => '找不到播客订阅源';

  @override
  String get adminPodcastsSearchHint => '搜索播客…';

  @override
  String get adminPodcastsSearchItunesHint => '在 iTunes 中搜索...';

  @override
  String adminPodcastsSearchItunesFor(String query) {
    return '在 iTunes 中搜索「$query」';
  }

  @override
  String get adminPodcastsNoPodcastsFound => '未找到播客';

  @override
  String get adminPodcastsRelToday => '今天';

  @override
  String adminPodcastsWeeksAgo(int count) {
    return '$count 周前';
  }

  @override
  String adminPodcastsMonthsAgo(int count) {
    return '$count 个月前';
  }

  @override
  String adminPodcastsYearsAgo(int count) {
    return '$count 年前';
  }

  @override
  String adminPodcastsUpdated(String when) {
    return '更新于 $when';
  }

  @override
  String get adminPodcastsGenreAll => '全部';

  @override
  String get adminPodcastsGenreArts => '艺术';

  @override
  String get adminPodcastsGenreComedy => '喜剧';

  @override
  String get adminPodcastsGenreEducation => '教育';

  @override
  String get adminPodcastsGenreTvFilm => '影视';

  @override
  String get adminPodcastsGenreMusic => '音乐';

  @override
  String get adminPodcastsGenreNews => '新闻';

  @override
  String get adminPodcastsGenreReligion => '宗教';

  @override
  String get adminPodcastsGenreScience => '科学';

  @override
  String get adminPodcastsGenreSports => '体育';

  @override
  String get adminPodcastsGenreTechnology => '科技';

  @override
  String get adminPodcastsGenreBusiness => '商业';

  @override
  String get adminPodcastsGenreFiction => '小说';

  @override
  String get adminPodcastsGenreSocietyCulture => '社会与文化';

  @override
  String get adminPodcastsGenreHealthFitness => '健康与健身';

  @override
  String get adminPodcastsGenreTrueCrime => '真实犯罪';

  @override
  String get adminPodcastsGenreHistory => '历史';

  @override
  String get adminPodcastsGenreKidsFamily => '儿童与家庭';

  @override
  String get adminPodcastsPodcastFallback => '播客';

  @override
  String get adminPodcastsEpisodeFallback => '单集';

  @override
  String get adminPodcastsNoFeedFound => '未找到订阅源 URL';

  @override
  String get adminPodcastsNoFeedAvailable => '没有可用的订阅源 URL';

  @override
  String adminPodcastsAddedToLibrary(String title) {
    return '「$title」已添加到媒体库';
  }

  @override
  String adminPodcastsFailedToAdd(String title) {
    return '无法添加 $title';
  }

  @override
  String adminPodcastsEpisodesInFeed(int count) {
    return '订阅源中共有 $count 个单集';
  }

  @override
  String adminPodcastsMoreEpisodes(int count) {
    return '+ $count 个更多单集';
  }

  @override
  String get adminPodcastsAdding => '正在添加…';

  @override
  String get adminPodcastsAddToLibrary => '添加到媒体库';

  @override
  String get adminPodcastsRemoveShowTitle => '移除节目？';

  @override
  String adminPodcastsRemoveShowContent(String title) {
    return '从服务器中移除「$title」及其所有单集？此操作无法撤销。';
  }

  @override
  String adminPodcastsRemovedShow(String title) {
    return '已移除「$title」';
  }

  @override
  String get adminPodcastsFailedRemoveShow => '无法移除节目';

  @override
  String get adminPodcastsRemoveShowTooltip => '移除节目';

  @override
  String get adminPodcastsSelectMultipleTooltip => '多选';

  @override
  String adminPodcastsDownloadedCount(int count) {
    return '已下载 $count 个';
  }

  @override
  String get adminPodcastsTabDownloaded => '已下载';

  @override
  String get adminPodcastsTabFeed => '订阅源';

  @override
  String get adminPodcastsTabSettings => '设置';

  @override
  String adminPodcastsDownloadingEpisode(String title) {
    return '正在下载「$title」';
  }

  @override
  String get adminPodcastsFailedDownload => '下载失败';

  @override
  String get adminPodcastsDeleteEpisodeTitle => '删除单集？';

  @override
  String adminPodcastsDeleteEpisodeContent(String title) {
    return '删除「$title」？';
  }

  @override
  String get adminPodcastsDeleted => '已删除';

  @override
  String get adminPodcastsFailed => '失败';

  @override
  String get adminPodcastsDeleteEpisodesTitle => '删除单集？';

  @override
  String adminPodcastsDeleteEpisodesContent(int count) {
    return '从服务器中删除 $count 个单集？';
  }

  @override
  String adminPodcastsDeletedEpisodes(int count) {
    return '已删除 $count 个单集';
  }

  @override
  String get adminPodcastsBrowseFeedToDownload => '浏览订阅源以下载';

  @override
  String get adminPodcastsDownloadingDots => '正在下载...';

  @override
  String adminPodcastsDeleteEpisodesCount(int count) {
    return '删除 $count 个单集';
  }

  @override
  String adminPodcastsDownloadingCount(int count) {
    return '正在下载 $count 个单集';
  }

  @override
  String adminPodcastsDownloadEpisodesCount(int count) {
    return '下载 $count 个单集';
  }

  @override
  String get adminPodcastsLookForEpisodesAfter => '查找此日期之后的单集';

  @override
  String get adminPodcastsSelectDate => '选择日期';

  @override
  String get adminPodcastsMaxEpisodes => '最大下载单集数';

  @override
  String adminPodcastsNoNewEpisodesAfter(String date) {
    return '$date 之后没有找到新单集';
  }

  @override
  String adminPodcastsFoundNewEpisodes(int count) {
    return '找到 $count 个新单集 - 正在下载';
  }

  @override
  String get adminPodcastsFailedToCheckNew => '检查新单集失败';

  @override
  String get adminPodcastsCheckAndDownload => '检查并下载';

  @override
  String get adminPodcastsMatchPodcast => '匹配播客';

  @override
  String get adminPodcastsMatchPodcastSubtitle => '在 iTunes 中搜索以更新封面和元数据';

  @override
  String get adminPodcastsAutoDownloadNewEpisodes => '自动下载新单集';

  @override
  String get adminPodcastsAutoDownloadOnSubtitle => '服务器自动下载新单集';

  @override
  String get adminPodcastsAutoDownloadOffSubtitle => '新单集不会自动下载';

  @override
  String get adminPodcastsFailedAutoDownloadUpdate => '无法更新自动下载设置';

  @override
  String get adminPodcastsMaxEpisodesToKeep => '保留的最大单集数';

  @override
  String get adminPodcastsMaxEpisodesToKeepHelp =>
      '0 表示保留所有单集。当自动下载新单集后，如果节目超过此上限，Audiobookshelf 会移除最旧的单集。';

  @override
  String get adminPodcastsNoEpisodeLimit => '无限制';

  @override
  String get adminPodcastsEpisodeLimitInvalid => '请输入 0 或一个整数';

  @override
  String get adminPodcastsCheckSchedule => '检查计划';

  @override
  String get adminPodcastsFrequency => '频率';

  @override
  String get adminPodcastsFreqHourly => '每小时';

  @override
  String get adminPodcastsFreqDaily => '每天';

  @override
  String get adminPodcastsFreqWeekly => '每周';

  @override
  String get adminPodcastsDay => '日期';

  @override
  String get adminPodcastsTime => '时间';

  @override
  String get adminPodcastsDaySun => '周日';

  @override
  String get adminPodcastsDayMon => '周一';

  @override
  String get adminPodcastsDayTue => '周二';

  @override
  String get adminPodcastsDayWed => '周三';

  @override
  String get adminPodcastsDayThu => '周四';

  @override
  String get adminPodcastsDayFri => '周五';

  @override
  String get adminPodcastsDaySat => '周六';

  @override
  String get adminPodcastsFeedUrl => '订阅源 URL';

  @override
  String get adminPodcastsBack => '返回';

  @override
  String get adminPodcastsRootOnly => '仅 Root 用户';

  @override
  String get adminPodcastsDeleting => '正在删除...';

  @override
  String get adminPodcastsDeleteEpisode => '删除单集';

  @override
  String adminPodcastsSeasonChip(String season) {
    return '第 $season 季';
  }

  @override
  String adminPodcastsEpChip(String number) {
    return '第 $number 集';
  }

  @override
  String get adminPodcastsApplyingMatch => '正在应用匹配...';

  @override
  String get adminPodcastsNoResults => '无结果';

  @override
  String get adminPodcastsPodcastMatched => '播客已匹配并更新';

  @override
  String get adminPodcastsFailedMatch => '匹配播客失败';

  @override
  String get adminPodcastsSelectAll => '全选';

  @override
  String get adminPodcastsSelectAllNew => '仅新的';

  @override
  String get adminPodcastsSortNewestFirst => '最新的在前';

  @override
  String get adminPodcastsSortOldestFirst => '最旧的在前';

  @override
  String get adminPodcastsEditInfo => '编辑信息';

  @override
  String get adminPodcastsEditInfoSubtitle => '修改标题、描述、封面等';

  @override
  String get adminPodcastsEditTitle => '编辑播客';

  @override
  String get adminPodcastsReleaseDate => '发布日期';

  @override
  String get adminPodcastsExplicit => '敏感内容';

  @override
  String get adminPodcastsExplicitSubtitle => '将此播客标记为敏感内容';

  @override
  String get episodeListEpisodeFallback => '单集';

  @override
  String get episodeListUnknownPodcast => '未知播客';

  @override
  String episodeListMarkedFinished(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个单集已标记为完成',
      one: '1 个单集已标记为完成',
    );
    return '$_temp0';
  }

  @override
  String episodeListMarkedUnfinished(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个单集已标记为未完成',
      one: '1 个单集已标记为未完成',
    );
    return '$_temp0';
  }

  @override
  String get episodeListUnsubscribeFromNewEpisodes => '取消订阅新单集';

  @override
  String get episodeListSubscribeToNewEpisodes => '订阅新单集';

  @override
  String get episodeListSubscribeTitle => '订阅此播客？';

  @override
  String get episodeListSubscribeContent => '当服务器上出现新单集时，它们将被自动下载并添加到您的收听队列中。';

  @override
  String get episodeListSubscribe => '订阅';

  @override
  String get episodeListShowFinishedEpisodes => '显示已完成的单集';

  @override
  String get episodeListHideFinishedEpisodes => '隐藏已完成的单集';

  @override
  String get episodeListShowSettings => '显示设置';

  @override
  String get episodeListPlaysNewerToOlder => '从新到旧播放';

  @override
  String get episodeListPlaysOlderToNewer => '从旧到新播放';

  @override
  String episodeListEpisodeCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个单集',
      one: '1 个单集',
    );
    return '$_temp0';
  }

  @override
  String episodeListUnfinishedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个未完成',
      one: '1 个未完成',
    );
    return '$_temp0';
  }

  @override
  String get episodeListAutoDownloadChip => '自动下载';

  @override
  String get episodeListSubscribedChip => '已订阅';

  @override
  String get episodeListExplicitChip => '敏感';

  @override
  String get episodeListSortNewest => '最新';

  @override
  String get episodeListSortOldest => '最旧';

  @override
  String get episodeListSortBy => '单集排序';

  @override
  String get episodeListSortPubDate => '发布日期';

  @override
  String get episodeListSortTitle => '标题';

  @override
  String get episodeListSortSeason => '季';

  @override
  String get episodeListSortEpisode => '单集编号';

  @override
  String get episodeListSortFileName => '文件名';

  @override
  String get episodeListSortReverseHint => '再次点击可反转顺序';

  @override
  String episodeListAddedToAbsorbing(String title) {
    return '已将「$title」添加到收听中';
  }

  @override
  String get episodeDetailEpisodeFallback => '单集';

  @override
  String get episodeDetailMarkedNotFinished => '已标记为未完成';

  @override
  String get episodeDetailMarkedFinishedNice => '已标记为完成 - 干得漂亮！';

  @override
  String get episodeDetailMarkAbsorbedContent => '这会将此单集的进度设置为 100%。';

  @override
  String get episodeDetailResetProgressContent =>
      '这将清除此单集的所有进度并将其重置到开头。此操作无法撤销。';

  @override
  String get episodeDetailToday => '今天';

  @override
  String get episodeDetailYesterday => '昨天';

  @override
  String episodeDetailDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String episodeDetailWeeksAgo(int count) {
    return '$count 周前';
  }

  @override
  String episodeDetailDurationHm(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String episodeDetailDurationM(int minutes) {
    return '$minutes 分';
  }

  @override
  String get episodeDetailResume => '继续播放';

  @override
  String get episodeDetailPlayEpisode => '播放单集';

  @override
  String episodeDetailEpisodeNumber(String number) {
    return '第 $number 集';
  }

  @override
  String episodeDetailSeasonNumber(String number) {
    return '第 $number 季';
  }

  @override
  String get editMetadataUpdatedFromMatch => '已根据匹配更新元数据';

  @override
  String editMetadataConfirmMatch(String title) {
    return '这将使用以下内容更新此书的服务器元数据:\n\n「$title」\n\n服务器上的所有字段和封面都将被覆盖。';
  }

  @override
  String editMetadataConfirmMatchWithAuthor(String title, String author) {
    return '这将使用以下内容更新此书的服务器元数据:\n\n「$title」（作者 $author）\n\n服务器上的所有字段和封面都将被覆盖。';
  }

  @override
  String get seriesBooksFindMissingTitle => '扫描缺失书籍';

  @override
  String get seriesBooksFindMissingContent =>
      '此功能将检索 Audible以查找该系列中你的媒体库可能缺失的书籍。\n\n系统会优先通过 ASIN 进行匹配（取决于你的服务器中书籍是否包含 ASIN），若无则通过书名进行匹配。搜索结果可能不会完全准确。';

  @override
  String get seriesBooksCouldNotFindOnAudible => '在 Audible 上找不到此系列';

  @override
  String seriesBooksMarkAllNotFinishedContent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '这将清除该系列中全部 $count 本书的完成状态。',
      one: '这将清除该系列中 1 本书的完成状态。',
    );
    return '$_temp0';
  }

  @override
  String seriesBooksFullyAbsorbContent(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '这将把该系列中的全部 $count 本书标记为已完成。',
      one: '这将把该系列中的 1 本书标记为已完成。',
    );
    return '$_temp0';
  }

  @override
  String get seriesBooksUnmarkAll => '全部取消标记';

  @override
  String get seriesBooksShowAllBooks => '显示所有书籍';

  @override
  String get seriesBooksGroupBySubSeries => '按子系列分组';

  @override
  String get seriesBooksLoadingSubSeries => '正在加载子系列...';

  @override
  String seriesBooksBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 本书',
      one: '1 本书',
    );
    return '$_temp0';
  }

  @override
  String get seriesBooksDone => '完成';

  @override
  String get seriesBooksExplicitBadge => 'E';

  @override
  String get expandedCardStreaming => '串流播放';

  @override
  String get expandedCardDeviceFallback => '设备';

  @override
  String bookmarksScreenPositionInBook(String position, String bookTitle) {
    return '$position（在《$bookTitle》中）';
  }

  @override
  String get bookmarksScreenClose => '关闭';

  @override
  String get bookmarksScreenSortNewest => '最新';

  @override
  String get bookmarksScreenSortPosition => '位置';

  @override
  String statsScreenStreakDays(int count) {
    return '$count 天';
  }

  @override
  String statsScreenSessionCountOne(int count) {
    return '$count 个会话';
  }

  @override
  String statsScreenSessionCountOther(int count) {
    return '$count 个会话';
  }

  @override
  String get statsScreenDayMon => '周一';

  @override
  String get statsScreenDayTue => '周二';

  @override
  String get statsScreenDayWed => '周三';

  @override
  String get statsScreenDayThu => '周四';

  @override
  String get statsScreenDayFri => '周五';

  @override
  String get statsScreenDaySat => '周六';

  @override
  String get statsScreenDaySun => '周日';

  @override
  String statsScreenDurationHm(int h, int m) {
    return '$h 小时 $m 分';
  }

  @override
  String statsScreenDurationM(int m) {
    return '$m 分';
  }

  @override
  String get statsScreenDurationLessThanMin => '不足 1 分钟';

  @override
  String get statsScreenDurationZero => '0 分钟';

  @override
  String statsScreenDurationShortH(int h) {
    return '$h 小时';
  }

  @override
  String statsScreenDurationShortM(int m) {
    return '$m 分';
  }

  @override
  String get statsScreenCouldNotLoadItem => '无法加载项目';

  @override
  String get statsScreenCouldNotFindEpisode => '找不到单集';

  @override
  String statsScreenByAuthor(String author) {
    return '作者 $author';
  }

  @override
  String get statsScreenListened => '已收听';

  @override
  String get sessionEditTitle => '编辑会话';

  @override
  String get sessionDayLabel => '日期';

  @override
  String get sessionEndPosition => '结束位置';

  @override
  String get sessionEndPositionHint => '修改此项可能会同时更新您当前的进度。';

  @override
  String get statsViewSessions => '查看会话';

  @override
  String statsSessionsForDate(String date) {
    return '$date 的会话';
  }

  @override
  String get statsNoSessionsForDate => '这一天没有找到收听会话';

  @override
  String get statsSearchSessions => '搜索会话';

  @override
  String get statsNoSessionSearchResults => '没有会话符合您的搜索条件';

  @override
  String get statsSessionsLoadFailed => '无法加载这一天的会话';

  @override
  String get sessionDeleteConfirmTitle => '删除会话？';

  @override
  String get sessionDeleteConfirmBody => '这将移除该会话，并按相应时长减少您的收听总计。此操作无法撤销。';

  @override
  String get sessionSaved => '会话已更新';

  @override
  String get sessionDeleted => '会话已删除';

  @override
  String get sessionSaveFailed => '无法保存更改';

  @override
  String get sessionDeleteFailed => '无法删除此会话';

  @override
  String get statsScreenStartedAtPosition => '开始位置';

  @override
  String get statsScreenEndedAtPosition => '结束位置';

  @override
  String get statsScreenTotalDuration => '总时长';

  @override
  String get statsScreenStarted => '开始';

  @override
  String get statsScreenUpdated => '更新';

  @override
  String get statsScreenClient => '客户端';

  @override
  String get statsScreenDevice => '设备';

  @override
  String get statsScreenOs => '系统';

  @override
  String get statsScreenPlayMethod => '播放方式';

  @override
  String get statsScreenLoading => '加载中...';

  @override
  String get statsScreenJumpToStart => '跳到开头';

  @override
  String get statsScreenJumpToEnd => '跳到结尾';

  @override
  String get statsScreenPlayMethodDirect => '直接播放';

  @override
  String get statsScreenPlayMethodDirectStream => '直接流式播放';

  @override
  String get statsScreenPlayMethodTranscode => '转码';

  @override
  String get statsScreenPlayMethodLocal => '本地';

  @override
  String get statsScreenAmLabel => '上午';

  @override
  String get statsScreenPmLabel => '下午';

  @override
  String statsScreenDateAtTime(
    String month,
    int day,
    int year,
    int hour,
    String minute,
    String ampm,
  ) {
    return '$year年$month月$day日 $hour:$minute $ampm';
  }

  @override
  String get statsScreenMonthJan => '1月';

  @override
  String get statsScreenMonthFeb => '2月';

  @override
  String get statsScreenMonthMar => '3月';

  @override
  String get statsScreenMonthApr => '4月';

  @override
  String get statsScreenMonthMay => '5月';

  @override
  String get statsScreenMonthJun => '6月';

  @override
  String get statsScreenMonthJul => '7月';

  @override
  String get statsScreenMonthAug => '8月';

  @override
  String get statsScreenMonthSep => '9月';

  @override
  String get statsScreenMonthOct => '10月';

  @override
  String get statsScreenMonthNov => '11月';

  @override
  String get statsScreenMonthDec => '12月';

  @override
  String get upcomingReleasesTitle => '即将上架';

  @override
  String get upcomingReleasesRescanTitle => '重新扫描？';

  @override
  String upcomingReleasesRescanContent(int days) {
    return '这些结果是 $days 天前获取的。发布日期可能已发生变更——是否需要重新扫描？';
  }

  @override
  String get upcomingReleasesNotNow => '稍后再说';

  @override
  String get upcomingReleasesRescan => '重新扫描';

  @override
  String get upcomingReleasesRescanReleaseDate => '重新扫描发布日期';

  @override
  String get upcomingReleasesRescanning => '正在重新扫描...';

  @override
  String upcomingReleasesUpdatedWithDate(String date) {
    return '更新于 $date';
  }

  @override
  String get upcomingReleasesNoReleaseDateFound => '未找到发布日期';

  @override
  String get upcomingReleasesRescanFailed => '重新扫描失败';

  @override
  String get upcomingReleasesRemoveFromList => '从列表中移除';

  @override
  String get upcomingReleasesRemovedFromList => '已从列表中移除';

  @override
  String get upcomingReleasesDateChip => '发布日期';

  @override
  String upcomingReleasesCheckingSeries(String name, int processed, int total) {
    return '正在获取 $name... ($processed/$total)';
  }

  @override
  String get upcomingReleasesLoadingSeries => '系列加载中...';

  @override
  String get upcomingReleasesScannedToday => '(今天已扫描)';

  @override
  String get upcomingReleasesScannedYesterday => '(昨天已扫描)';

  @override
  String upcomingReleasesScannedDaysAgo(int days) {
    return '(扫描于 $days 天前)';
  }

  @override
  String upcomingReleasesUpcomingCount(int count) {
    return '$count 个即将发布';
  }

  @override
  String upcomingReleasesRecentCount(int count) {
    return '$count 个最近更新';
  }

  @override
  String get upcomingReleasesNoneFound => '未找到即将推出或最近更新的内容';

  @override
  String upcomingReleasesAcrossSeries(String summary, int count) {
    return '$summary共 $count 个系列';
  }

  @override
  String upcomingReleasesCheckedSeries(int count) {
    return '已扫描 Audible 上的 $count 个系列';
  }

  @override
  String upcomingReleasesDateFormat(String month, int day, int year) {
    return '$year-$month-$day';
  }

  @override
  String upcomingReleasesSequenceLabel(String sequence) {
    return '#$sequence';
  }

  @override
  String get upcomingReleasesBadgeUpcoming => '即将发布';

  @override
  String get upcomingReleasesBadgeAdded => '已添加';

  @override
  String get upcomingReleasesBadgeMissing => '缺失';

  @override
  String get upcomingReleasesScanSettingsTitle => '扫描设置';

  @override
  String get upcomingReleasesFinishedAfterTitle => '多长时间未出新作即视为系列完结';

  @override
  String get upcomingReleasesFinishedAfterDesc =>
      '最后一本书早于该时间的系列会在扫描时跳过，仅每一两个月重新检查一次。';

  @override
  String upcomingReleasesFinishedAfterYears(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 年',
      one: '1 年',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesFinishedAfterNever => '永不';

  @override
  String get upcomingReleasesSkippedTitle => '跳过的系列';

  @override
  String get upcomingReleasesSkippedNone => '尚未跳过任何内容';

  @override
  String upcomingReleasesSkippedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '跳过 $count 个',
      one: '跳过 1 个',
    );
    return '$_temp0';
  }

  @override
  String upcomingReleasesSkippedLastBook(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '最后一本书在 $count 年前',
      one: '最后一本书在 1 年前',
      zero: '最后一本书不足一年',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesSkippedUnmatched => '无法在 Audible 上匹配此系列';

  @override
  String get upcomingReleasesSkippedScanNow => '立即扫描';

  @override
  String get upcomingReleasesSkippedAlwaysScan => '始终扫描';

  @override
  String get upcomingReleasesSkippedNeverScan => '永不扫描';

  @override
  String upcomingReleasesSkippedScanFound(String name) {
    return '在 $name 中发现了新发布';
  }

  @override
  String upcomingReleasesSkippedScanNone(String name) {
    return '$name 中没有新内容';
  }

  @override
  String get upcomingReleasesSkippedOtherLibrary => '此列表来自另一个媒体库。运行重新扫描以刷新它。';

  @override
  String get upcomingReleasesChipUpcoming => '即将发布';

  @override
  String upcomingReleasesChipMissing(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '缺失 $count 个',
      one: '缺失 1 个',
      zero: '缺失',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesNoMissing => '未发现缺失书籍';

  @override
  String get upcomingReleasesScanSeries => '扫描系列';

  @override
  String get upcomingReleasesScanUpcomingOption => '即将发布';

  @override
  String get upcomingReleasesScanUpcomingOptionDesc => '快速扫描新书和即将上架的书';

  @override
  String get upcomingReleasesScanDeepOption => '深度扫描';

  @override
  String get upcomingReleasesScanDeepOptionDesc => '同时查找每个系列中缺失的书籍 - 耗时更长';

  @override
  String get upcomingReleasesFirstScanNote =>
      '首次扫描会检查 Audible 上的每个系列，可能需要几分钟。系列整理完成后，后续扫描会快得多。';

  @override
  String get upcomingReleasesLastScanReport => '上次扫描报告';

  @override
  String upcomingReleasesReportChecked(int count) {
    return '已在 Audible 上检查: $count';
  }

  @override
  String upcomingReleasesReportSkipped(int count) {
    return '已跳过: $count';
  }

  @override
  String upcomingReleasesReportUnmatched(int count) {
    return '无法在 Audible 上匹配: $count';
  }

  @override
  String upcomingReleasesReportFailed(int count) {
    return '检查失败: $count';
  }

  @override
  String upcomingReleasesReportFound(int upcoming, int recent) {
    return '发现 $upcoming 个即将发布，$recent 个近期发布';
  }

  @override
  String upcomingReleasesReportFoundDeep(
    int upcoming,
    int recent,
    int missing,
  ) {
    return '发现 $upcoming 个即将发布，$recent 个近期发布，$missing 个缺失';
  }

  @override
  String upcomingReleasesReportMore(int count) {
    return '+$count 更多';
  }

  @override
  String get upcomingReleasesBadgeNew => '新';

  @override
  String get upcomingReleasesOpenLibrarySeries => '在媒体库中打开系列';

  @override
  String get upcomingReleasesAsinCopied => '系列 ASIN 已复制';

  @override
  String get upcomingReleasesSetSeriesAsin => '设置系列 ASIN';

  @override
  String get upcomingReleasesSetAsinInstructions =>
      '在 audible.com 上找到该系列并复制页面链接 - ASIN 是以 B0 开头的 10 位代码（如 B08S2YN3YS）。粘贴完整链接也可以。';

  @override
  String get upcomingReleasesSetAsinHint => 'B0… 或 audible.com 链接';

  @override
  String get upcomingReleasesSetAsinSave => '保存';

  @override
  String get upcomingReleasesSetAsinInvalid => '该文本中未找到 ASIN';

  @override
  String get upcomingReleasesSetAsinSaved => '系列已关联 - 正在扫描';

  @override
  String upcomingReleasesRemoveTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '移除 $count 本书',
      one: '移除书籍',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesRemoveThisScan => '从本次扫描中移除';

  @override
  String get upcomingReleasesRemoveThisScanDesc => '可能在未来扫描中重新出现';

  @override
  String get upcomingReleasesRemoveForever => '从本次及未来的扫描中移除';

  @override
  String get upcomingReleasesRemoveForeverDesc => '将移至已移除列表，可随时恢复';

  @override
  String get upcomingReleasesRemovedForeverToast => '已移除 - 不会在未来的扫描中显示';

  @override
  String get upcomingReleasesRemovedBooksTitle => '已移除的书籍';

  @override
  String upcomingReleasesRemovedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 本书',
      one: '1 本书',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesRemovedNone => '没有被移除的书籍';

  @override
  String get upcomingReleasesRestore => '恢复';

  @override
  String get upcomingReleasesRestoredToast => '已恢复';

  @override
  String get upcomingReleasesRestoredNextScan => '已恢复 - 将在下次扫描后显示';

  @override
  String upcomingReleasesSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已选择 $count 个',
      one: '已选择 1 个',
    );
    return '$_temp0';
  }

  @override
  String get upcomingReleasesBulkRequest => '请求';

  @override
  String get upcomingReleasesBulkRemove => '移除';

  @override
  String upcomingReleasesBulkRemoved(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已移除 $count 个',
      one: '已移除 1 个',
    );
    return '$_temp0';
  }

  @override
  String upcomingReleasesBulkRequestDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已发送 $count 个请求',
      one: '已发送 1 个请求',
    );
    return '$_temp0';
  }

  @override
  String upcomingReleasesBulkRequestSkipped(int count) {
    return '已跳过 $count 个';
  }

  @override
  String upcomingReleasesBulkScanned(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已重新扫描 $count 个系列',
      one: '已重新扫描 1 个系列',
    );
    return '$_temp0';
  }

  @override
  String upcomingReleasesBulkScanFound(int count) {
    return '$count 个有新书';
  }

  @override
  String get seriesExcludeFromScan => '从系列扫描中排除';

  @override
  String get seriesIncludeInScan => '纳入系列扫描';

  @override
  String get homeScreenEpisodeFallback => '单集';

  @override
  String get libraryScreenUnknownTitle => '未知标题';

  @override
  String get playlistDetailDefaultName => '播放列表';

  @override
  String playlistDetailItemCount(int count) {
    return '$count 个项目';
  }

  @override
  String get playlistDetailUnfinished => '未完成';

  @override
  String get playlistDetailRemoveFromPlaylist => '从播放列表中移除';

  @override
  String get playlistDetailDone => '完成';

  @override
  String playlistDetailItemsMarkedFinished(int count) {
    return '已标记 $count 个项目为完成';
  }

  @override
  String playlistDetailItemsMarkedUnfinished(int count) {
    return '已标记 $count 个项目为未完成';
  }

  @override
  String playlistDetailItemsRemoved(int count) {
    return '已移除 $count 个项目';
  }

  @override
  String playlistDetailAddedToAbsorbing(String title) {
    return '已将「$title」添加到收听中';
  }

  @override
  String get collectionDetailDefaultName => '收藏集';

  @override
  String collectionDetailBookCount(int count) {
    return '$count本书';
  }

  @override
  String get collectionDetailDone => '完成';

  @override
  String collectionDetailAddedToAbsorbing(String title) {
    return '已将「$title」添加到收听中';
  }

  @override
  String get audibleSeriesNoBooksFound => '未在 Audible 上找到书籍';

  @override
  String get audibleSeriesFailedToLoad => '无法从 Audible 加载系列';

  @override
  String audibleSeriesSummary(int total, int missing) {
    return 'Audible 共 $total 本 · 缺失 $missing';
  }

  @override
  String audibleSeriesSummaryWithUpcoming(
    int total,
    int missing,
    int upcoming,
  ) {
    return 'Audible 共 $total 本 · 缺失 $missing · 即将发布 $upcoming';
  }

  @override
  String audibleSeriesFilterMissing(int count) {
    return '缺失 ($count)';
  }

  @override
  String audibleSeriesFilterUpcoming(int count) {
    return '即将发布 ($count)';
  }

  @override
  String audibleSeriesFilterAll(int count) {
    return '全部 ($count)';
  }

  @override
  String get audibleSeriesSearching => '正在搜索 Audible...';

  @override
  String get audibleSeriesCompleteSeries => '您已拥有完整系列！';

  @override
  String get audibleSeriesNoUpcoming => '未找到即将上架的内容';

  @override
  String get audibleSeriesUpcomingBadge => '即将发布';

  @override
  String get audibleSeriesAbridged => '删节版';

  @override
  String get audibleSeriesRegionTitle => 'Audible 区域';

  @override
  String get audibleSeriesOpenOnAudible => '在 Audible 上打开';

  @override
  String get audibleSeriesAddToCalendar => '添加到日历';

  @override
  String get audibleSeriesAddToUpcoming => '添加到即将上架';

  @override
  String get audibleSeriesAddedToUpcoming => '已添加到即将上架';

  @override
  String get audibleSeriesAlreadyInUpcoming => '已在即将上架页面中';

  @override
  String get audibleSeriesCouldNotOpenAudible => '无法打开 Audible';

  @override
  String get audibleSeriesCouldNotOpenCalendar => '无法打开日历';

  @override
  String audibleSeriesCalendarDescription(String seriesName) {
    return '$seriesName 系列的新有声书发布';
  }

  @override
  String get authorBooksGroupBySeries => '按系列分组';

  @override
  String get authorBooksList => '列表';

  @override
  String get authorBooksGrid => '网格';

  @override
  String authorBooksBookCount(int count) {
    return '$count 本书';
  }

  @override
  String get metadataLookupCover => '封面';

  @override
  String get metadataLookupChooseFields => '选择要应用的字段';

  @override
  String metadataLookupApplyFields(int count) {
    return '应用 $count 个字段';
  }

  @override
  String metadataLookupFieldsSavedLocally(int count) {
    return '$count 个字段已本地保存';
  }

  @override
  String get metadataLookupOverrideLocalDisplay => '覆盖本地显示';

  @override
  String get equalizerPresetFlat => '原声';

  @override
  String get equalizerPresetVoiceBoost => '人声增强';

  @override
  String get equalizerPresetBassBoost => '低音增强';

  @override
  String get equalizerPresetTrebleBoost => '高音增强';

  @override
  String get equalizerPresetPodcast => '播客模式';

  @override
  String get equalizerPresetAudiobook => '有声书';

  @override
  String get equalizerPresetReduceNoise => '降噪模式';

  @override
  String get equalizerPresetLoudness => '响度';

  @override
  String equalizerEditingSavedNamed(String title) {
    return '正在编辑\"$title\"';
  }

  @override
  String get equalizerEditingSavedGeneric => '正在编辑已保存的均衡器';

  @override
  String get equalizerPerBookEq => '每本书单独配置';

  @override
  String get notesDeleteNoteQuestion => '删除笔记？';

  @override
  String notesDeleteNoteContent(String title) {
    return '删除「$title」？';
  }

  @override
  String get notesExport => '导出';

  @override
  String get notesNewNote => '新建笔记';

  @override
  String get librarySortFilterUpcomingReleases => '即将发布';

  @override
  String get librarySortFilterMatchAllAuthorsSubtitle => '从元数据提供商为每位作者获取照片和简介';

  @override
  String get librarySortFilterUpcomingReleasesSubtitle => 'Audible 中检查系列新书';

  @override
  String sleepTimerSheetChaptersLeft(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '剩余 $count 章',
      one: '剩余 1 章',
    );
    return '$_temp0';
  }

  @override
  String sleepTimerSheetAddMinutesChip(int minutes) {
    return '+$minutes 分';
  }

  @override
  String sleepTimerSheetAddChaptersChip(int count) {
    return '+$count 章';
  }

  @override
  String sleepTimerSheetMinShort(int minutes) {
    return '$minutes 分';
  }

  @override
  String sleepTimerHoursOnly(int hours) {
    return '$hours 时';
  }

  @override
  String sleepTimerHoursMinutes(int hours, int minutes) {
    return '$hours 时 $minutes 分';
  }

  @override
  String sleepTimerStartDuration(String duration) {
    return '启动 $duration 定时器';
  }

  @override
  String sleepTimerLastUsed(String duration) {
    return '上次定时 $duration';
  }

  @override
  String get sleepTimerCustom => '自定义';

  @override
  String get sleepTimerWheelHourUnit => '时';

  @override
  String get sleepTimerWheelMinuteUnit => '分';

  @override
  String sleepTimerSheetSecondsShort(int seconds) {
    return '$seconds 秒';
  }

  @override
  String sleepTimerSheetMinSecShort(int minutes, int seconds) {
    return '$minutes 分 $seconds 秒';
  }

  @override
  String sleepTimerSheetChaptersValue(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 章',
      one: '1 章',
    );
    return '$_temp0';
  }

  @override
  String sleepTimerSheetChaptersChip(int count) {
    return '$count 章';
  }

  @override
  String sleepTimerSheetStartChapterSleep(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '听完 $count 章结束',
      one: '听完 1 章结束',
    );
    return '$_temp0';
  }

  @override
  String get sleepTimerSheetRewindOnSleep => '定时结束自动倒回';

  @override
  String get sleepTimerSheetShake => '摇一摇';

  @override
  String sleepTimerSheetAddsMinutes(int minutes) {
    return '添加 $minutes 分钟';
  }

  @override
  String get sleepTimerSheetAddsOneChapter => '添加 1 章';

  @override
  String get sleepTimerSheetResetsToFull => '重置为完整时长';

  @override
  String get sleepTimerSheetTabSpecificChapter => '章节';

  @override
  String get sleepTimerSheetSpecificNoChapters => '没有可用的章节';

  @override
  String sleepTimerSheetSpecificChapterFallback(int number) {
    return '第 $number 章';
  }

  @override
  String get sleepTimerSheetSpecificPassedShort => '已过';

  @override
  String get sleepTimerSheetSpecificStart => '章节开始';

  @override
  String get sleepTimerSheetSpecificEnd => '章节结束';

  @override
  String get sleepTimerSheetSpecificEndsAt => '睡眠定时器将于';

  @override
  String sleepTimerSheetSpecificCountdown(String countdown) {
    return '$countdown 后';
  }

  @override
  String get sleepTimerSheetSpecificAlreadyPassed => '此时间点已过';

  @override
  String get sleepTimerSheetSpecificStartButton => '启动定时器';

  @override
  String get sleepTimerSheetSpecificStartButtonPassed => '已过';

  @override
  String get timeAm => '上午';

  @override
  String get timePm => '下午';

  @override
  String get collectionPickerCollectionFallback => '收藏集';

  @override
  String collectionPickerNameWithCount(String name, int count) {
    return '$name ($count)';
  }

  @override
  String get playlistPickerPlaylistFallback => '播放列表';

  @override
  String playlistPickerNameWithCount(String name, int count) {
    return '$name ($count)';
  }

  @override
  String get cardChaptersPlayFromChapterTitle => '从该章节开始播放？';

  @override
  String cardChaptersPlayFromChapterContent(String title) {
    return '从「$title」开始播放？';
  }

  @override
  String get cardChaptersPlay => '播放';

  @override
  String get absorbingSharedToday => '今天';

  @override
  String get absorbingSharedYesterday => '昨天';

  @override
  String get absorbingSharedMonday => '星期一';

  @override
  String get absorbingSharedTuesday => '星期二';

  @override
  String get absorbingSharedWednesday => '星期三';

  @override
  String get absorbingSharedThursday => '星期四';

  @override
  String get absorbingSharedFriday => '星期五';

  @override
  String get absorbingSharedSaturday => '星期六';

  @override
  String get absorbingSharedSunday => '星期日';

  @override
  String get absorbingSharedAm => '上午';

  @override
  String get absorbingSharedPm => '下午';

  @override
  String sectionDetailAddedToAbsorbing(String title) {
    return '已将「$title」添加到收听中';
  }

  @override
  String get sectionDetailDoneBadge => '完成';

  @override
  String get homeCustomizeAddGenreTitle => '新增类型分区';

  @override
  String get homeCustomizeAddGenreSubtitle => '选择一个类型显示在你的首页';

  @override
  String get homeSectionDoneBadge => '完成';

  @override
  String get tipsSheetQuickBookmarksTitle => '快速书签';

  @override
  String get tipsSheetQuickBookmarksDesc => '长按任意卡片上的书签按钮即可立即添加书签，无需打开书签页面。';

  @override
  String get tipsSheetCoverPlayPauseTitle => '点击封面播放/暂停';

  @override
  String get tipsSheetCoverPlayPauseDesc =>
      '点击任意卡片的封面即可播放或暂停。可在设置的“收听卡片”中切换此功能。播放时会显示淡淡的暂停图标，提示封面可点击。';

  @override
  String get tipsSheetFullScreenPlayerTitle => '全屏播放器';

  @override
  String get tipsSheetFullScreenPlayerDesc => '在任意沉浸卡片上向上滑动即可打开全屏播放器，向下滑动即可关闭。';

  @override
  String get tipsSheetQuickAddAbsorbingTitle => '快速加入收听卡片';

  @override
  String get tipsSheetQuickAddAbsorbingDesc =>
      '在列表页（系列、作者、搜索结果）中向右滑动任意书籍，即可将其立即加入收听队列。';

  @override
  String get tipsSheetShakeExtendSleepTitle => '摇一摇延长睡眠定时';

  @override
  String get tipsSheetShakeExtendSleepDesc =>
      '如果睡眠定时器正在运行，摇动手机即可延长时间。可在设置中的“睡眠定时器”调整延长的分钟数。';

  @override
  String get tipsSheetSeriesNavigationTitle => '系列导航';

  @override
  String get tipsSheetSeriesNavigationDesc =>
      '在任意书籍的详情弹窗中点击系列名称，即可查看该系列的所有书籍，并按阅读顺序排序，每本书的封面都会显示序号徽章。';

  @override
  String get tipsSheetSwipeBetweenBooksTitle => '滑动切换书籍';

  @override
  String get tipsSheetSwipeBetweenBooksDesc =>
      '在收听界面左右滑动即可切换你正在收听的书籍。开启手动队列模式后，卡片也会作为你的队列使用，因此当前书籍播放结束时会自动播放下一本。';

  @override
  String get tipsSheetTapToSeekTitle => '点击跳转';

  @override
  String get tipsSheetTapToSeekDesc =>
      '点击章节或书籍进度条的任意位置即可直接跳转到对应进度。你也可以拖动进度条以进行更精细的控制。';

  @override
  String get tipsSheetSpeedAdjustedTimeTitle => '实际播放时长';

  @override
  String get tipsSheetSpeedAdjustedTimeDesc =>
      '剩余时间和章节时长会根据你的播放速度自动调整。用 1.5×倍播放？界面显示的时间就是你实际需要的时长。';

  @override
  String get tipsSheetPlaybackHistoryTitle => '播放历史';

  @override
  String get tipsSheetPlaybackHistoryDesc =>
      '点击任意卡片上的历史按钮即可查看所有播放、暂停、跳转和倍速调整的时间线。点击任意事件即可跳回对应位置。';

  @override
  String get tipsSheetAutoRewindTitle => '自动回退';

  @override
  String get tipsSheetAutoRewindDesc =>
      '暂停后恢复播放时，Absorb 会自动回退几秒，确保你不会错过内容。回退时长会根据你离开的时间自动调整。你可以在设置中进行修改。';

  @override
  String get tipsSheetSeriesQueueModeTitle => '系列连播模式';

  @override
  String get tipsSheetSeriesQueueModeDesc =>
      '当你听完某个系列中的一本书时，Absorb 可以自动播放下一本书。请在“设置”中将队列模式更改为“系列”。';

  @override
  String get tipsSheetOfflineModeTitle => '离线模式';

  @override
  String get tipsSheetOfflineModeDesc =>
      '点击“正在收听”界面上的同步图标即可进入离线模式。这将暂停同步并节省流量，且仅显示你已下载的书籍。非常适合在飞机上或信号较弱的区域使用。';

  @override
  String get tipsSheetUpcomingReleasesTitle => '即将上架';

  @override
  String get tipsSheetUpcomingReleasesDesc =>
      '在“系列”标签页中，再次点击该标签即可打开其排序与筛选面板，然后选择“即将上架”，即可按出版日期查看当前系列中已推出和即将推出的新书。';

  @override
  String get tipsSheetPerBookEqTitle => '为每本书单独配置均衡器';

  @override
  String get tipsSheetPerBookEqDesc =>
      '每本书都会记住自己的均衡器设置。为一部科幻巨作调整一次均衡器，下次播放时它的声音依旧。';

  @override
  String get tipsSheetPerBookSpeedTitle => '针对单本有声书的语速设置';

  @override
  String get tipsSheetPerBookSpeedDesc =>
      '播放速度支持书籍单独配置。非虚构内容 1.5x 效率拉满，有声剧 1.0x 原汁原味，省去频繁调整的麻烦。';

  @override
  String get tipsSheetAutoSleepWindowTitle => '自动睡眠时间段';

  @override
  String get tipsSheetAutoSleepWindowDesc => '设定您常睡的时间段，在此时间段内听书，睡眠定时器将自动启用。';

  @override
  String get tipsSheetSleepFadeChimeTitle => '睡眠淡出与提示音';

  @override
  String get tipsSheetSleepFadeChimeDesc =>
      '睡眠定时结束时，音频将逐渐淡出并伴有可选提示音，避免在听书时突然中断。';

  @override
  String get tipsSheetCarModeTitle => '车载模式';

  @override
  String get tipsSheetCarModeDesc => '轻点汽车图标，开启车载模式，让行车操作更安全舒适。';

  @override
  String get tipsSheetAudibleSeriesTitle => '获取 Audible 系列信息';

  @override
  String get tipsSheetAudibleSeriesDesc =>
      '打开任意系列，点击右上角的“更多”图标（三个点），即可从 Audible 获取完整的系列清单，包含缺失以及您尚未开始阅读的书籍。';

  @override
  String get tipsSheetTranscribeBookmarkTitle => '转写书签';

  @override
  String get tipsSheetTranscribeBookmarkDesc =>
      '将任意书签处的音频转为文字，全程在您的设备上完成。在设置的“高级 > 转写”中启用并下载模型，然后点击书签上的“转写” - 文字会保存到其笔记中，方便整理或分享。';

  @override
  String get tipsSheetFindBetweenFormatsTitle => '在有声书和电子书之间跳转';

  @override
  String get tipsSheetFindBetweenFormatsDesc =>
      '开启转写并下载书籍后，暂停并点击播放器上的“在电子书中查找位置”，即可在电子书中定位到您刚刚听到的段落。在阅读器中选中一段文字并点击耳机图标，即可从该处开始播放有声书。';

  @override
  String get tipsSheetShareQuoteTitle => '分享引用';

  @override
  String get tipsSheetShareQuoteDesc =>
      '将电子书划线或书签笔记以图片形式分享，引用覆盖在书籍封面上。在划线和书签面板中寻找分享选项。';

  @override
  String get tipsSheetClipExportTitle => '导出音频片段';

  @override
  String get tipsSheetClipExportDesc =>
      '打开一个书签并点击“导出片段”，即可剪辑并保存一段包含封面图的书籍音频片段 - 非常适合分享精彩片段。';

  @override
  String get tipsSheetAllHighlightsTitle => '所有划线集中一处';

  @override
  String get tipsSheetAllHighlightsDesc =>
      '“全部书签”页面有一个“划线”标签页，汇集了所有书籍的电子书划线。点击一条即可分享或跳回书中。';

  @override
  String get tipsSheetVolumeKeyPagesTitle => '音量键翻页';

  @override
  String get tipsSheetVolumeKeyPagesDesc =>
      '使用音量键翻阅电子书页面。在阅读器设置中启用 - 可正序或镜像方向，音频播放时也可继续使用。';

  @override
  String get tipsSheetSettingsSyncTitle => '设置同步';

  @override
  String get tipsSheetSettingsSyncDesc =>
      '通过您自己的 WebDAV 服务器，在多台设备间保持设置、每本书的速度和收听顺序同步。在设置的“备份和同步”中配置。';

  @override
  String get tipsSheetNavLongPressTitle => '长按底部标签页';

  @override
  String get tipsSheetNavLongPressDesc => '从任意页面长按首页标签即可切换媒体库。长按媒体库标签可直达搜索。';

  @override
  String get bookCardUnknownTitle => '未知标题';

  @override
  String get bookCardExplicitBadge => 'E';

  @override
  String get bookCardDone => '完成';

  @override
  String get bookCardSaved => '已保存';

  @override
  String get episodeRowEpisode => '单集';

  @override
  String get episodeRowToday => '今天';

  @override
  String get episodeRowYesterday => '昨天';

  @override
  String episodeRowDaysAgo(int count) {
    return '$count 天前';
  }

  @override
  String episodeRowWeeksAgo(int count) {
    return '$count 周前';
  }

  @override
  String episodeRowDurationHm(int hours, int minutes) {
    return '$hours 小时 $minutes 分';
  }

  @override
  String episodeRowDurationM(int minutes) {
    return '$minutes 分';
  }

  @override
  String episodeRowSeasonShort(String number) {
    return 'S$number';
  }

  @override
  String episodeRowEpisodeShort(String number) {
    return 'E$number';
  }

  @override
  String get librarySearchResultsExplicitBadge => 'E';

  @override
  String get librarySearchResultsDone => '完成';

  @override
  String get librarySearchResultsSaved => '已保存';

  @override
  String librarySearchResultsSequence(String number) {
    return '第 $number 部';
  }

  @override
  String get librarySearchResultsUnknownSeries => '未知系列';

  @override
  String get librarySearchResultsUnknownEpisode => '未知单集';

  @override
  String librarySearchResultsBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 本书',
      one: '1 本书',
    );
    return '$_temp0';
  }

  @override
  String get libraryGridTilesExplicitBadge => 'E';

  @override
  String get libraryGridTilesDone => '完成';

  @override
  String get libraryGridTilesSaved => '已保存';

  @override
  String libraryGridTilesSequence(String number) {
    return '第 $number 部';
  }

  @override
  String get libraryGridTilesUnknownSeries => '未知系列';

  @override
  String get seriesCardUnknownSeries => '未知系列';

  @override
  String seriesCardBookCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 本书',
      one: '1 本书',
    );
    return '$_temp0';
  }

  @override
  String get cardProgressFineScrubbing => '精细拖动';

  @override
  String get cardProgressQuarterSpeed => '四分之一速度';

  @override
  String get cardProgressHalfSpeed => '半速';

  @override
  String cardProgressChapterPrefix(String number) {
    return '第 $number 章';
  }

  @override
  String get cardEdgeProgressFineScrubbing => '精细拖动';

  @override
  String get cardEdgeProgressQuarterSpeed => '四分之一速度';

  @override
  String get cardEdgeProgressHalfSpeed => '半速';

  @override
  String get authSessionExpired => '会话已过期，请重新登录。';

  @override
  String authCannotReachServer(String url) {
    return '无法访问 $url 处的服务器';
  }

  @override
  String get authInvalidUsernameOrPassword => '用户名或密码无效';

  @override
  String get authInvalidApiKey => 'API 密钥无效';

  @override
  String get authLoginFailedDetail => '登录失败 - 请检查您的服务器地址和凭据';

  @override
  String get authUnexpectedServerResponse => '服务器返回了意外响应';

  @override
  String get authSsoUnexpectedResponse => 'SSO 返回了意外响应';

  @override
  String get authSwitchedToLocalServer => '已切换到本地服务器';

  @override
  String get authSwitchedToRemoteServer => '已切换到远程服务器';

  @override
  String get lpDeletedFinishedDownload => '已删除已完成的下载';

  @override
  String lpSubscribedPodcastDownloading(String showTitle, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '正在下载 $count 个新单集',
      one: '正在下载 1 个新单集',
    );
    return '$showTitle: $_temp0';
  }

  @override
  String lpSubscribedEpisodeAddedStart(String showTitle) {
    return '$showTitle 已添加到队列顶部';
  }

  @override
  String lpSubscribedEpisodeAddedSecond(String showTitle) {
    return '$showTitle 已添加到队列第 2 位';
  }

  @override
  String lpSubscribedEpisodeAddedEnd(String showTitle) {
    return '$showTitle 已添加到队列末尾';
  }

  @override
  String lpSubscribedEpisodeDownloaded(String showTitle) {
    return '已下载 $showTitle 的新单集';
  }

  @override
  String get statsWeekStartsOn => '每周从哪一天开始';

  @override
  String get episodeListNewEpisodePosition => '新单集位置';

  @override
  String get episodeListPositionTop => '队列顶部';

  @override
  String get episodeListPositionSecond => '队列第 2 位';

  @override
  String get episodeListPositionEnd => '队列末尾';

  @override
  String get episodeListPositionNone => '不加入队列';

  @override
  String get episodeListPositionNoneDesc => '仍会通知并下载';

  @override
  String sleepRewindUndoNote(int minutes) {
    return '在 $minutes 分钟内按下播放即可撤销倒回';
  }

  @override
  String lpQueueDownloadingItems(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '队列: 正在下载 $count 个项目',
      one: '队列: 正在下载 1 个项目',
    );
    return '$_temp0';
  }

  @override
  String lpDownloadingBooks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '正在下载 $count 本书',
      one: '正在下载 1 本书',
    );
    return '$_temp0';
  }

  @override
  String lpDownloadingEpisodes(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '正在下载 $count 个单集',
      one: '正在下载 1 个单集',
    );
    return '$_temp0';
  }

  @override
  String get downloadNotifProgressChannelName => '下载进度';

  @override
  String get downloadNotifProgressChannelDesc => '有声书下载期间显示进度';

  @override
  String get downloadNotifAlertChannelName => '下载提醒';

  @override
  String get downloadNotifAlertChannelDesc => '下载完成或失败时的通知';

  @override
  String get downloadNotifDownloadingTitle => '正在下载…';

  @override
  String downloadNotifActiveCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个下载任务进行中',
      one: '1 个下载任务进行中',
    );
    return '$_temp0';
  }

  @override
  String downloadNotifSlotTitle(String title) {
    return '正在下载: $title';
  }

  @override
  String get downloadNotifStartingLabel => '正在开始…';

  @override
  String get downloadNotifCompleteTitle => '下载完成';

  @override
  String downloadNotifCompleteBody(String title) {
    return '《$title》已经下载好，随时随地开始听吧';
  }

  @override
  String get downloadNotifFailedTitle => '下载失败';

  @override
  String get upcomingNotifChannelName => '扫描即将发布内容';

  @override
  String get upcomingNotifChannelDesc => '显示即将发布扫描的进度';

  @override
  String get upcomingNotifScanTitle => '即将发布内容扫描中';

  @override
  String get upcomingNotifStartingScan => '正在开始扫描…';

  @override
  String upcomingNotifCheckingSeries(
    String seriesName,
    int current,
    int total,
  ) {
    return '正在检查 $seriesName… ($current/$total)';
  }

  @override
  String get upcomingNotifFoundTitle => '查找到即将发布内容！';

  @override
  String upcomingNotifFoundBody(int books, int series) {
    String _temp0 = intl.Intl.pluralLogic(
      series,
      locale: localeName,
      other: '$series 个系列中',
      one: '1 个系列中',
    );
    return '$_temp0有 $books 个即将发布';
  }

  @override
  String get androidAutoTabContinue => '继续';

  @override
  String get androidAutoTabLibrary => '媒体库';

  @override
  String get androidAutoTabDownloads => '下载';

  @override
  String get settingsSearchHint => '搜索设置...';

  @override
  String get settingsSearchNoResults => '没有匹配的设置';

  @override
  String get carConnectAutoplay => 'Android Auto 连接时开始播放';

  @override
  String get carConnectAutoplayIos => 'CarPlay 连接时开始播放';

  @override
  String get carConnectAutoplayOnSubtitle => '汽车连接时，您最后收听的书籍会自动开始播放';

  @override
  String get carConnectAutoplayOffSubtitle => '播放等待您按下播放键';

  @override
  String get androidAutoCatBooks => '书籍';

  @override
  String get androidAutoCatSeries => '系列';

  @override
  String get androidAutoCatAuthors => '作者';

  @override
  String get showTipsAgain => '再次显示提示';

  @override
  String get showTipsAgainSubtitle => '恢复你已关闭的功能提示';

  @override
  String get tipsRestored => '已恢复提示';

  @override
  String get resetSpeedPresets => '重置速度预设';

  @override
  String get resetSpeedPresetsSubtitle => '恢复默认的播放速度选项';

  @override
  String get speedPresetsReset => '速度预设已重置';

  @override
  String get editAuthor => '编辑作者';

  @override
  String get authorName => '名称';

  @override
  String get authorImage => '作者照片';

  @override
  String get authorRemoveImage => '移除照片';

  @override
  String get authorRemoveImageTitle => '移除作者照片？';

  @override
  String get authorRemoveImageConfirm => '这将删除服务器上的照片。';

  @override
  String get authorImageRemoved => '照片已移除';

  @override
  String get authorImageFailed => '无法更新作者照片';

  @override
  String get authorUpdated => '作者已更新';

  @override
  String get authorUpdateFailed => '无法更新作者';

  @override
  String get authorMatched => '已根据匹配更新作者';

  @override
  String get authorNoMatchFound => '未找到匹配';

  @override
  String authorMergedInto(String name) {
    return '已合并到 $name';
  }

  @override
  String get authorQuickMatchHint => '从所选区域的 Audible 获取姓名、ASIN、描述和照片。';

  @override
  String get region => '区域';

  @override
  String get editTabDetails => '详情';

  @override
  String get editTabCover => '封面';

  @override
  String get editTabMatch => '匹配';

  @override
  String get editTabEmbed => '嵌入';

  @override
  String get chapterEditorTitle => '编辑章节';

  @override
  String get chapterNotConnected => '未连接到服务器';

  @override
  String get chapterErrorFirstNotZero => '第一章必须从 0:00 开始';

  @override
  String get chapterErrorStartAfterPrevious => '开始时间必须在上一个章节之后';

  @override
  String get chapterErrorStartBeforeEnd => '开始时间必须在书籍结束之前';

  @override
  String get chapterErrorTitleRequired => '必须填写标题';

  @override
  String get chapterEditStartTitle => '编辑开始时间';

  @override
  String get chapterTimeHintSeconds => '秒';

  @override
  String get chapterTimeHintFull => 'HH:MM:SS 或秒';

  @override
  String get chapterInvalidTime => '时间无效';

  @override
  String get chapterLocked => '章节已锁定';

  @override
  String get chapterAllLocked => '所有章节均已锁定';

  @override
  String chapterTrackTitle(int number) {
    return '第 $number 轨';
  }

  @override
  String get chapterNoAudioForPosition => '此位置没有音频';

  @override
  String get chapterCouldNotPlayPreview => '无法播放预览';

  @override
  String chapterStartSetTo(String time) {
    return '开始时间已设为 $time';
  }

  @override
  String get chapterAddNumberedTitle => '添加编号章节';

  @override
  String chapterNextPreview(String first, String second) {
    return '下一章: 「$first」、「$second」...';
  }

  @override
  String get chapterHowMany => '章节数量';

  @override
  String get add => '添加';

  @override
  String get chapterCountRange => '请输入 1 到 150 之间的数字';

  @override
  String get chapterTitlesUpdated => '章节标题已更新';

  @override
  String get chaptersApplied => '章节已应用';

  @override
  String get chapterDiscardTitle => '放弃更改？';

  @override
  String get chapterDiscardMessage => '还原为已保存的章节。';

  @override
  String get chapterRemoveAllTitle => '移除所有章节？';

  @override
  String get chapterRemoveAllMessage => '这将移除本书的所有章节。';

  @override
  String get chapterAllRemoved => '所有章节已移除';

  @override
  String get chapterFixHighlighted => '请先修复高亮显示的章节';

  @override
  String get chaptersUpdated => '章节已更新';

  @override
  String get ok => '确定';

  @override
  String get chapterSaveButton => '保存章节';

  @override
  String get chapterAddHint => '添加章节（例如「Chapter 01」）';

  @override
  String get chapterAddTooltip => '添加章节';

  @override
  String get chapterRemoveAll => '全部移除';

  @override
  String get chapterShiftTimes => '平移时间';

  @override
  String get chapterFromTracks => '从音轨';

  @override
  String get chapterLookup => '查找';

  @override
  String get chapterShowSeconds => '显示秒数';

  @override
  String get chapterShiftBySeconds => '平移（秒）';

  @override
  String get chapterShiftHint => '平移所有未锁定的章节。使用负值可将其提前。';

  @override
  String get chapterBack1Second => '后退 1 秒';

  @override
  String get chapterForward1Second => '前进 1 秒';

  @override
  String get chapterTitleHint => '章节标题';

  @override
  String get chapterStopPreview => '停止预览';

  @override
  String get chapterPreviewFromHere => '从此处预览';

  @override
  String get chapterScrubHint => '拖动到准确位置，然后设置';

  @override
  String chapterStartAt(String time) {
    return '从 $time 开始';
  }

  @override
  String get chapterSetStartHere => '在此处设置开始';

  @override
  String get chapterMore => '更多';

  @override
  String get chapterUnlock => '解锁';

  @override
  String get chapterLock => '锁定';

  @override
  String get chapterInsertBelow => '在下方插入';

  @override
  String get chapterFindTitle => '查找章节';

  @override
  String get chapterFindSubtitle => '通过 ASIN 从 Audible/Audnexus 查找章节。';

  @override
  String get chapterEnterAsin => '输入 ASIN';

  @override
  String get chapterLookupFailed => '查找失败 - 请检查 ASIN';

  @override
  String get chapterNoChaptersFound => '未找到该 ASIN 的章节';

  @override
  String get chapterRemoveBranding => '移除 Audible 品牌片头/片尾';

  @override
  String chapterFoundCount(int count) {
    return '找到 $count 个章节';
  }

  @override
  String chapterAudibleVsBook(String audible, String book) {
    return 'Audible $audible - 书本 $book';
  }

  @override
  String get chapterAudibleLonger => 'Audible 版本比您的文件更长 - 后面的章节可能无法对齐。';

  @override
  String get chapterAudibleShorter => 'Audible 版本比您的文件更短 - 章节可能无法对齐。';

  @override
  String get chapterTitlesOnly => '仅标题';

  @override
  String get chapterApplyChapters => '应用章节';

  @override
  String get coverSearchTitle => '搜索封面';

  @override
  String get coverSearchRefineHint => '优化标题/作者以整理搜索结果 - 这不会更改书籍。';

  @override
  String get coverNoneFound => '未找到封面';

  @override
  String get coverEnterTitleFirst => '请先输入标题';

  @override
  String get coverUpdated => '封面已更新';

  @override
  String get coverCouldNotUpdate => '无法更新封面';

  @override
  String get coverApply => '应用封面';

  @override
  String get coverUnknownResolution => '未知分辨率';

  @override
  String get embedIntro => '将元数据嵌入音频文件，包括封面图片和章节。';

  @override
  String get embedBackupOption => '先备份音频文件';

  @override
  String get embedNoteInFolder => '元数据将嵌入您有声读物文件夹中的音频音轨。';

  @override
  String get embedNoteMultiTrack => '章节不会嵌入多音轨有声读物。';

  @override
  String get embedNoteNavigateAway => '任务开始后，您可以离开此页面。';

  @override
  String get embedStartButton => '开始嵌入元数据';

  @override
  String embedProgress(String percent) {
    return '正在嵌入 $percent%';
  }

  @override
  String get embedProgressIndeterminate => '正在嵌入...';

  @override
  String taskProgressKeepsRunning(String percent) {
    return '$percent% - 离开此页面也会继续运行';
  }

  @override
  String get taskStarting => '正在开始...';

  @override
  String get embedBackupNoteIntro => '您的原始音频文件的备份将存储在服务器上的 ';

  @override
  String embedBackupNotePath(String itemId) {
    return '/metadata/cache/items/$itemId/';
  }

  @override
  String get embedBackupNoteOutro => '。请定期清理项目缓存。';

  @override
  String get embedDialogTitle => '嵌入元数据';

  @override
  String embedConfirmMessage(int count, String backup) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '# 个音频文件',
      one: '# 个音频文件',
    );
    return '将元数据嵌入 $_temp0？您的音频文件将被重写$backup。';
  }

  @override
  String get embedConfirmBackupClause => '（将先备份原件）';

  @override
  String get embedConfirmAction => '嵌入';

  @override
  String get embedCouldNotStart => '无法开始嵌入';

  @override
  String get embedStarted => '嵌入已开始';

  @override
  String get embedComplete => '嵌入完成';

  @override
  String get embedFailed => '嵌入失败';

  @override
  String get encodeComplete => '转码完成';

  @override
  String get encodeFailedTask => '转码失败';

  @override
  String encodeProgress(String percent) {
    return '正在转码 $percent%';
  }

  @override
  String get encodeProgressIndeterminate => '正在转码...';

  @override
  String get adminApiKeys => 'API 密钥';

  @override
  String get adminApiKeysSubtitle => '程序化访问令牌';

  @override
  String get adminApiKeysNewTitle => '新建 API 密钥';

  @override
  String get adminApiKeysName => '名称';

  @override
  String get adminApiKeysNameHint => '例如 Home Assistant';

  @override
  String get adminApiKeysOwner => '用户';

  @override
  String get adminApiKeysExpiration => '有效期';

  @override
  String get adminApiKeysActive => '激活';

  @override
  String get adminApiKeysActiveSub => '密钥创建后立即可用';

  @override
  String get adminApiKeysInactive => '未激活';

  @override
  String get adminApiKeysExpired => '已过期';

  @override
  String get adminApiKeysCreate => '创建密钥';

  @override
  String get adminApiKeysCreated => 'API 密钥已创建';

  @override
  String get adminApiKeysTokenLabel => '您的新 API 密钥';

  @override
  String get adminApiKeysCopyWarning => '请立即复制此密钥。出于安全考虑，它将不再显示。';

  @override
  String get adminApiKeysCopy => '复制';

  @override
  String get adminApiKeysCopied => '已复制到剪贴板';

  @override
  String get adminApiKeysDone => '完成';

  @override
  String get adminApiKeysDeleteTitle => '撤销 API 密钥？';

  @override
  String get adminApiKeysDeleted => 'API 密钥已撤销';

  @override
  String get adminApiKeysRevoke => '撤销';

  @override
  String get adminApiKeysSetActive => '设为激活';

  @override
  String get adminApiKeysSetInactive => '设为未激活';

  @override
  String get adminApiKeysFailedCreate => '无法创建 API 密钥';

  @override
  String get adminApiKeysFailedDelete => '无法撤销 API 密钥';

  @override
  String get adminApiKeysFailedUpdate => '无法更新 API 密钥';

  @override
  String get adminApiKeysEmpty => '还没有 API 密钥';

  @override
  String get adminApiKeysEmptySub => '创建一个，让应用和脚本能够访问您的服务器';

  @override
  String get adminApiKeysNeverUsed => '从未使用';

  @override
  String get adminApiKeysNeverExpires => '永不过期';

  @override
  String get adminApiKeysNameRequired => '请输入名称';

  @override
  String get adminApiKeysUserRequired => '请选择用户';

  @override
  String get adminApiKeysExpNever => '永不';

  @override
  String get adminApiKeysExp7d => '7 天';

  @override
  String get adminApiKeysExp30d => '30 天';

  @override
  String get adminApiKeysExp90d => '90 天';

  @override
  String get adminApiKeysExp1y => '1 年';

  @override
  String adminApiKeysLastUsed(String time) {
    return '最后使用于 $time';
  }

  @override
  String adminApiKeysExpiresOn(String date) {
    return '将于 $date 到期';
  }

  @override
  String adminApiKeysDeleteContent(String name) {
    return '撤销「$name」？使用此密钥的应用将立即失去访问权限。';
  }

  @override
  String get endOfEpisode => '本集结束';

  @override
  String get sleepTimerSheetEpisodeSleepStart => '在本集结束时睡眠';

  @override
  String get bookmarkListen => '试听';

  @override
  String get bookmarkPause => '暂停';

  @override
  String get bookmarkPreviewFailed => '无法播放此位置。';

  @override
  String get clipExport => '导出片段';

  @override
  String get clipJumpToStart => '跳到开头';

  @override
  String get clipJumpToEnd => '跳到结尾';

  @override
  String get clipSetStart => '设置开始';

  @override
  String get clipSetEnd => '设置结束';

  @override
  String get clipInLabel => '入点';

  @override
  String get clipOutLabel => '出点';

  @override
  String get clipSave => '保存片段';

  @override
  String clipExportSaved(String filename) {
    return '已保存 $filename';
  }

  @override
  String get clipExportClamped => '片段已保存，已缩短至此音轨结尾';

  @override
  String get clipExportFailed => '无法导出片段。';

  @override
  String get clipDownloadToExport => '请先下载此书，以便在 iPhone 上导出片段。';

  @override
  String get fsPickerTitle => '选择文件夹';

  @override
  String get fsServerRoot => '服务器根目录';

  @override
  String get fsEmptyFolder => '此处没有子文件夹';

  @override
  String get fsUseThisFolder => '使用此文件夹';

  @override
  String get adminLibrariesManage => '媒体库';

  @override
  String get adminLibrariesManageSubtitle => '创建、编辑和排序';

  @override
  String get adminUploadTitle => '上传媒体';

  @override
  String get adminUploadSubtitle => '从文件添加书籍和播客';

  @override
  String get adminUploadNoLibraries => '请先创建媒体库，再上传媒体。';

  @override
  String get adminUploadDestination => '目标位置';

  @override
  String get adminUploadFolder => '媒体库文件夹';

  @override
  String get adminUploadDetails => '项目详情';

  @override
  String get adminUploadOptional => '可选';

  @override
  String get adminUploadAutoMetadata => '自动获取元数据';

  @override
  String get adminUploadAutoMetadataSubtitle => '从最佳匹配填写标题、作者和系列';

  @override
  String get adminUploadMetadataProvider => '元数据提供商';

  @override
  String get adminUploadMetadataSearching => '正在搜索元数据...';

  @override
  String get adminUploadMetadataNoResults => '未找到匹配的元数据。您仍可上传此项目。';

  @override
  String get adminUploadMetadataFailed => '无法搜索元数据。您仍可上传此项目。';

  @override
  String get adminUploadDestinationPreview => '服务器目标位置';

  @override
  String get adminUploadFiles => '文件';

  @override
  String adminUploadSelectedFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
      one: '1 个文件',
    );
    return '$_temp0';
  }

  @override
  String get adminUploadChooseFiles => '选择文件';

  @override
  String get adminUploadAddFiles => '添加文件';

  @override
  String get adminUploadBookFilesHint => '选择音频或电子书文件。您也可以包含封面和元数据文件。';

  @override
  String get adminUploadPodcastFilesHint => '选择一个或多个音频文件。您也可以包含封面和元数据文件。';

  @override
  String get adminUploadUnsupportedFiles => '某些所选文件不受 Audiobookshelf 支持。';

  @override
  String get adminUploadFilePickerFailed => '无法打开所选文件。';

  @override
  String get adminUploadTitleRequired => '请输入标题';

  @override
  String get adminUploadLibraryRequired => '请选择媒体库';

  @override
  String get adminUploadFolderRequired => '请选择媒体库文件夹';

  @override
  String get adminUploadFilesRequired => '请至少选择一个文件';

  @override
  String get adminUploadPodcastFileRequired => '请为此播客至少选择一个音频文件。';

  @override
  String get adminUploadBookFileRequired => '请为此书籍至少选择一个音频或电子书文件。';

  @override
  String get adminUploadPathCheckFailed => '无法检查目标文件夹。未上传任何内容。';

  @override
  String get adminUploadDestinationExists => '该目标文件夹已存在于服务器上。';

  @override
  String adminUploadDestinationUsedBy(String title) {
    return '该目标位置已被「$title」使用。';
  }

  @override
  String get adminUploadUploading => '正在上传...';

  @override
  String adminUploadProgress(int percent) {
    return '正在上传 $percent%';
  }

  @override
  String get adminUploadButton => '上传';

  @override
  String adminUploadComplete(String title) {
    return '已上传「$title」';
  }

  @override
  String get adminUploadFailed => '上传失败';

  @override
  String adminUploadFailedReason(String error) {
    return '上传失败: $error';
  }

  @override
  String get adminUploadReselectFiles => '重试前请重新选择文件。';

  @override
  String get adminServerSettings => '服务器设置';

  @override
  String get adminServerSettingsSubtitle => '扫描器、存储和排序';

  @override
  String get adminStats => '统计信息';

  @override
  String get adminStatsSubtitle => '媒体库和收听总数';

  @override
  String get adminAllSessions => '全部会话';

  @override
  String get adminAllSessionsSubtitle => '查看和管理所有收听会话';

  @override
  String get adminSessionsAllUsers => '所有用户';

  @override
  String get adminSessionsEmpty => '暂无会话';

  @override
  String get statsLibraryTotals => '媒体库总计';

  @override
  String get statsTotalItems => '项目';

  @override
  String get statsAudioFiles => '音频文件';

  @override
  String get statsTotalSize => '总大小';

  @override
  String get statsBooks => '书籍';

  @override
  String get statsPodcasts => '播客';

  @override
  String get statsBooksSize => '书籍大小';

  @override
  String get statsYearReview => '年度回顾';

  @override
  String get statsNoYearData => '今年没有数据';

  @override
  String get statsListeningTime => '收听时长';

  @override
  String get statsSessions => '会话';

  @override
  String get statsBooksAdded => '添加的书籍';

  @override
  String get statsAuthorsAdded => '添加的作者';

  @override
  String get statsTopAuthors => '热门作者';

  @override
  String get statsTopNarrators => '热门朗读者';

  @override
  String get statsTopGenres => '热门体裁';

  @override
  String get srvScannerSection => '扫描器';

  @override
  String get srvFindCovers => '查找封面';

  @override
  String get srvCoverProvider => '封面提供商';

  @override
  String get srvParseSubtitles => '从文件名解析副标题';

  @override
  String get srvPreferMatched => '优先使用匹配到的元数据';

  @override
  String get srvDisableWatcher => '禁用文件夹监视器';

  @override
  String get srvStorageSection => '存储';

  @override
  String get srvStoreCover => '将封面与项目一起存储';

  @override
  String get srvStoreMetadata => '将元数据与项目一起存储';

  @override
  String get srvMetadataFormat => '元数据文件格式';

  @override
  String get srvFormatSection => '显示和格式';

  @override
  String get srvDateFormat => '日期格式';

  @override
  String get srvTimeFormat => '时间格式';

  @override
  String get srvLanguage => '服务器语言';

  @override
  String get srvChromecast => 'Chromecast 支持';

  @override
  String get srvAllowIframe => '允许 iframe 嵌入';

  @override
  String get srvSortingSection => '排序';

  @override
  String get srvIgnorePrefixes => '排序时忽略前缀';

  @override
  String get srvSortingPrefixes => '排序前缀';

  @override
  String get srvAddPrefix => '添加前缀';

  @override
  String get srvSave => '保存设置';

  @override
  String get srvSavePrefixes => '保存前缀';

  @override
  String get srvSaved => '设置已保存';

  @override
  String get srvSaveFailed => '无法保存设置';

  @override
  String get srvPrefixesSaved => '排序前缀已更新';

  @override
  String get libNoneYet => '还没有媒体库';

  @override
  String get libReorderFailed => '无法保存新顺序';

  @override
  String get libDeleteTitle => '删除媒体库？';

  @override
  String get libDeleteBody => '这将从服务器上永久移除该媒体库及其所有项目。';

  @override
  String get libDeleted => '媒体库已删除';

  @override
  String get libDeleteFailed => '无法删除媒体库';

  @override
  String libFolderCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件夹',
      one: '1 个文件夹',
    );
    return '$_temp0';
  }

  @override
  String get libNewTitle => '新建媒体库';

  @override
  String get libEditTitle => '编辑媒体库';

  @override
  String get libName => '媒体库名称';

  @override
  String get libMediaType => '媒体类型';

  @override
  String get libMediaBook => '书籍';

  @override
  String get libMediaPodcast => '播客';

  @override
  String get libProvider => '元数据提供商';

  @override
  String get libIcon => '图标';

  @override
  String get libFolders => '文件夹';

  @override
  String get libAddFolder => '添加文件夹';

  @override
  String get libNoFolders => '至少添加一个文件夹';

  @override
  String get libAdvanced => '高级设置';

  @override
  String get libCoverShape => '封面形状';

  @override
  String get libCoverSquare => '方形';

  @override
  String get libCoverStandard => '标准';

  @override
  String get libDisableWatcher => '禁用文件夹监视器';

  @override
  String get libSkipAsin => '跳过已含 ASIN 的书籍匹配';

  @override
  String get libSkipIsbn => '跳过已含 ISBN 的书籍匹配';

  @override
  String get libHideSingleSeries => '隐藏单本书系列';

  @override
  String get libAudiobooksOnly => '仅有声书';

  @override
  String get libEpubScripted => '允许脚本化 ePub 内容';

  @override
  String get libLaterBooksOnly => '“继续系列”中仅显示之后的书籍';

  @override
  String get libPodcastRegion => '播客搜索区域';

  @override
  String get libMarkPercent => '完成于进度 %';

  @override
  String get libMarkTime => '完毕时剩余秒数';

  @override
  String get libAutoScan => '自动扫描计划 (cron)';

  @override
  String get libCreate => '创建媒体库';

  @override
  String get libUpdate => '保存更改';

  @override
  String get libNameRequired => '请输入媒体库名称';

  @override
  String get libCreated => '媒体库已创建';

  @override
  String get libCreateFailed => '无法创建媒体库';

  @override
  String get libUpdated => '媒体库已更新';

  @override
  String get libUpdateFailed => '无法更新媒体库';

  @override
  String get libRemoveFoldersTitle => '移除文件夹？';

  @override
  String get libRemoveFoldersBody => '移除文件夹会将该文件夹中的项目从媒体库中删除。此操作无法撤销。';

  @override
  String get readEbook => '阅读';

  @override
  String get homeTapCardToResume => '点按卡片继续收听，长按查看详情。';

  @override
  String get libraryTabLists => '书单';

  @override
  String get statsYearInReview => '年度回顾';

  @override
  String statsYirNothingYet(int year) {
    return '$year年还没有收听记录';
  }

  @override
  String get statsYirBooksFinished => '听完的书';

  @override
  String get statsYirSessions => '收听次数';

  @override
  String get statsYirBooksListened => '听过的书';

  @override
  String get statsYirTopMonth => '收听最多的月份';

  @override
  String get statsYirTopNarrator => '收听最多的朗读者';

  @override
  String get statsYirLongestFinished => '听完最长的书';

  @override
  String get removeFromNowPlaying => '从正在收听中移除';

  @override
  String get speedPresetsHint => '点按 + 可将当前速度存为预设，长按预设可删除。';

  @override
  String get monthShortJan => '1月';

  @override
  String get monthShortFeb => '2月';

  @override
  String get monthShortMar => '3月';

  @override
  String get monthShortApr => '4月';

  @override
  String get monthShortMay => '5月';

  @override
  String get monthShortJun => '6月';

  @override
  String get monthShortJul => '7月';

  @override
  String get monthShortAug => '8月';

  @override
  String get monthShortSep => '9月';

  @override
  String get monthShortOct => '10月';

  @override
  String get monthShortNov => '11月';

  @override
  String get monthShortDec => '12月';

  @override
  String get monthFullJan => '1月';

  @override
  String get monthFullFeb => '2月';

  @override
  String get monthFullMar => '3月';

  @override
  String get monthFullApr => '4月';

  @override
  String get monthFullMay => '5月';

  @override
  String get monthFullJun => '6月';

  @override
  String get monthFullJul => '7月';

  @override
  String get monthFullAug => '8月';

  @override
  String get monthFullSep => '9月';

  @override
  String get monthFullOct => '10月';

  @override
  String get monthFullNov => '11月';

  @override
  String get monthFullDec => '12月';

  @override
  String get wordingClassicTitle => '经典用语';

  @override
  String get wordingClassicOnSubtitle => '使用\"播放\"、\"正在播放\"、\"已完成\"';

  @override
  String get wordingClassicOffSubtitle => '使用\"收听\"、\"正在收听\"、\"已完全收听\"';

  @override
  String get rotationLockTitle => '锁定屏幕旋转';

  @override
  String get rotationLockOnSubtitle => '屏幕保持竖屏';

  @override
  String get rotationLockOffSubtitle => '屏幕可随设备旋转';

  @override
  String get duckTitle => '短暂中断时降低音量';

  @override
  String get duckOnSubtitle => '收到通知或提示时降低音量而非暂停';

  @override
  String get duckOffSubtitle => '收到通知或提示时暂停播放';

  @override
  String get autoSeriesDownloadTitle => '自动下载系列书籍';

  @override
  String get autoSeriesDownloadOnSubtitle => '开始收听系列中的一本书时，自动保持后续书籍已下载';

  @override
  String get autoSeriesDownloadOffSubtitle => '自行在系列菜单中开启系列下载';

  @override
  String get serverLogsEmpty => '暂无服务器日志';

  @override
  String get serverLogsNoMatch => '没有匹配的日志';

  @override
  String get serverLogsLoadFailed => '无法加载服务器日志';

  @override
  String get serverLogsDisplay => '最低显示级别';

  @override
  String get serverLogsLevel => '服务器日志级别';

  @override
  String get serverLogsSavingLevel => '正在保存日志级别…';

  @override
  String get serverLogsLevelTrace => '追踪';

  @override
  String get serverLogsLevelDebug => '调试';

  @override
  String get serverLogsLevelInfo => '信息';

  @override
  String get serverLogsLevelWarning => '警告';

  @override
  String get serverLogsFilterAll => '所有级别';

  @override
  String get serverLogsFilterTracePlus => '追踪';

  @override
  String get serverLogsFilterDebugPlus => '调试';

  @override
  String get serverLogsFilterInfoPlus => '信息';

  @override
  String get serverLogsFilterWarningPlus => '警告';

  @override
  String get serverLogsFilterErrorPlus => '错误';

  @override
  String get ebookDownload => '下载';

  @override
  String get ebookDownloaded => '已下载';

  @override
  String get ebookSavedOffline => '已保存供离线阅读';

  @override
  String get ebookRemovedOffline => '已从离线移除';

  @override
  String get ebookOfflineFailed => '无法下载电子书';

  @override
  String get ebookSaveToDevice => '保存到设备';

  @override
  String get ebookSaveToDeviceTitle => '保存到设备？';

  @override
  String get ebookSaveToDeviceBody =>
      '这会在您的设备上某处（由您选择位置）保存一份电子书文件的副本。它不会让这本书在阅读器中离线可用 - 如需离线，请使用“下载”。';

  @override
  String get readerFormatUnsupported => '阅读器暂不支持打开此电子书格式';

  @override
  String get moreActions => '更多';

  @override
  String get readerChapters => '章节';

  @override
  String get readerSettings => '阅读器设置';

  @override
  String get readerFontSize => '字体大小';

  @override
  String get readerLineSpacing => '行距';

  @override
  String get readerSideMargins => '侧边距';

  @override
  String get readerTopBottom => '上&下';

  @override
  String get readerPageLayout => '页面布局';

  @override
  String get readerPinTopBar => '始终显示标题和进度条';

  @override
  String get readerPinTopBarHint => '将标题和进度条固定到页面顶部，而不是点击时显示。页面会稍短一些，以免遮挡文字。';

  @override
  String get readerLayoutAuto => '自动';

  @override
  String get readerLayoutSingle => '单页';

  @override
  String get readerLayoutTwoPage => '双页';

  @override
  String get readerTheme => '主题';

  @override
  String get readerFont => '字体';

  @override
  String get readerVolumeNav => '音量键翻页';

  @override
  String get readerVolumeNavOff => '关闭';

  @override
  String get readerVolumeNavNormal => '正常';

  @override
  String get readerVolumeNavMirrored => '镜像';

  @override
  String get readerAutoScroll => '自动滚动';

  @override
  String get readerAutoScrollSubtitle => '下一页从顶部向下覆盖当前页 - 拖动屏幕中央可更改速度，点击可停止';

  @override
  String get readerAutoScrollStarted => '自动滚动已开始';

  @override
  String get readerAutoScrollPaused => '已暂停 - 长按可停止';

  @override
  String get readerAutoScrollResumed => '自动滚动已恢复';

  @override
  String get readerAutoScrollStopped => '自动滚动已关闭';

  @override
  String get readerAutoScrollEndOfBook => '书已读完 - 自动滚动已关闭';

  @override
  String readerAutoScrollSpeed(int percent) {
    return '速度 $percent%';
  }

  @override
  String get readerVolumeNavWhilePlaying => '音频播放时也生效';

  @override
  String get readerMoreFonts => '下载更多字体';

  @override
  String get readerFontRemove => '移除下载';

  @override
  String readerFontDownloadFailed(String font) {
    return '无法下载 $font';
  }

  @override
  String get readerAnnotations => '标注';

  @override
  String readerHighlights(int count) {
    return '划线 ($count)';
  }

  @override
  String readerBookmarks(int count) {
    return '书签 ($count)';
  }

  @override
  String get readerNoHighlights => '还没有划线';

  @override
  String get readerNoBookmarks => '还没有书签';

  @override
  String get readerBookmarkDefault => '书签';

  @override
  String get readerNoteTitle => '笔记';

  @override
  String get readerNoteHint => '添加笔记...';

  @override
  String get backupAndSync => '备份和同步';

  @override
  String get backupAndSyncSubtitle => '保存备份文件，或在多台设备间保持设置一致';

  @override
  String get syncSettingsExperimental => '实验性';

  @override
  String get syncSettingsExperimentalBody =>
      '同步功能还很新，仍在完善中。如果两台设备在离线期间各自修改了设置，其中一方可能会丢失更改。请保留一份备份文件作为安全副本。';

  @override
  String get syncSettingsNeedServer => '需要服务器？';

  @override
  String get syncSettingsNeedServerSub =>
      '任何 WebDAV 服务器都可以。Nextcloud 就是一种免费的、可自托管的选择。';

  @override
  String get syncSettingsConnection => '连接';

  @override
  String get syncSettingsConnectionNotSet => '尚未设置';

  @override
  String get syncSettingsBackupFile => '备份文件';

  @override
  String get syncSettingsBackupFilePlain => '将所有内容保存到一个您自行保管的文件中。';

  @override
  String get syncSettingsBackupFileWithSync =>
      '将所有内容保存到一个您自行保管的文件中。包含登录信息，在另一台手机上恢复它也会在那里开启同步。';

  @override
  String get syncSettingsStatusOff => '未在同步';

  @override
  String get syncSettingsStatusProblem => '无法访问您的服务器';

  @override
  String get syncSettings => '在设备之间同步设置';

  @override
  String get syncSettingsExtras => '同时同步';

  @override
  String get syncSettingsIncludeRmab => 'ReadMeABook 设置';

  @override
  String get syncSettingsIncludeRmabSub => '将您的 ReadMeABook API 令牌放入同步文件中';

  @override
  String get syncSettingsSubtitle => '通过您自己的 WebDAV 服务器保持设备间设置一致';

  @override
  String get syncSettingsEnable => '同步设置';

  @override
  String get syncSettingsServerUrl => 'WebDAV 文件夹 URL';

  @override
  String get syncSettingsServerUrlHint =>
      'https://cloud.example.com/remote.php/dav/files/you/Absorb';

  @override
  String get syncSettingsUsername => '用户名';

  @override
  String get syncSettingsPassword => '密码';

  @override
  String get syncSettingsHeaders => '自定义请求头（可选）';

  @override
  String get syncSettingsHeadersHint => '每行一个，例如 CF-Access-Client-Id: abc123';

  @override
  String get syncSettingsTest => '测试连接';

  @override
  String get syncSettingsHoldToUpload => '长按立即上传';

  @override
  String get syncSettingsUploadNow => '立即上传';

  @override
  String get syncSettingsDownloadNow => '立即下载';

  @override
  String get syncSettingsOk => '已连接';

  @override
  String get syncSettingsNoRemote => '已连接 - 尚未同步任何内容';

  @override
  String get syncSettingsAuthFailed => '用户名或密码错误';

  @override
  String get syncSettingsNetworkError => '无法访问该地址';

  @override
  String get syncSettingsNotConfigured => '请先填写地址、用户名和密码';

  @override
  String get syncSettingsTooLarge => '您的设置过大，无法同步';

  @override
  String get syncSettingsUploaded => '设置已上传';

  @override
  String get syncSettingsApplied => '已从您的另一台设备更新设置';

  @override
  String syncSettingsAppliedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '已从您的另一台设备更新 $count 项设置',
      one: '已从您的另一台设备更新 1 项设置',
    );
    return '$_temp0';
  }

  @override
  String get syncSettingsUpToDate => '已是最新';

  @override
  String syncSettingsLastSynced(String when) {
    return '上次同步于 $when';
  }

  @override
  String get syncSettingsNever => '尚未同步';

  @override
  String navHoldPickTitle(String tab) {
    return '按住 $tab 将…';
  }

  @override
  String get navHoldPickBody => '选择长按此标签页的操作。以后可在设置中更改。';

  @override
  String get navHoldSettingTitle => '标签页长按快捷操作';

  @override
  String get navHoldSettingSubtitle => '长按每个标签页的操作';

  @override
  String get navHoldAskNextTime => '下次询问';

  @override
  String get navHoldNothing => '无';

  @override
  String get navHoldPlayPause => '播放 / 暂停';

  @override
  String get navHoldOfflineMode => '离线模式';

  @override
  String get navHoldOfflineOn => '离线模式已开启';

  @override
  String get navHoldOfflineOff => '离线模式已关闭';

  @override
  String get navHoldMenu => '始终显示菜单';

  @override
  String get navHoldStop => '停止播放';

  @override
  String get navHoldRmabSearch => 'ReadMeABook 搜索';

  @override
  String get navHoldRmabRequests => '我的书籍请求';

  @override
  String get navHoldRmabWeb => 'ReadMeABook 网站';

  @override
  String get navHoldAdd => '添加';

  @override
  String get navHoldMoveLeft => '向左移动';

  @override
  String get navHoldMoveRight => '向右移动';

  @override
  String get navHoldRemoveFromMenu => '从菜单中移除';

  @override
  String get navHoldEditHint => '按住项目可移动或移除';

  @override
  String get navHoldResetMenu => '重置长按菜单项目';

  @override
  String get navHoldMenuReset => '菜单项目已重置';

  @override
  String get bookStatsAction => '收听统计';

  @override
  String get bookStatsYou => '您';

  @override
  String get bookStatsEveryone => '所有人';

  @override
  String get bookStatsListened => '收听时长';

  @override
  String get bookStatsSessions => '会话';

  @override
  String get bookStatsFirst => '首次收听';

  @override
  String get bookStatsLast => '最近收听';

  @override
  String get bookStatsListeners => '已开始收听的人数';

  @override
  String get bookStatsFinishedCount => '已听完的人数';

  @override
  String get bookStatsTotalTime => '所有人的收听时长';

  @override
  String get bookStatsNobody => '还没有人开始收听';

  @override
  String get bookStatsScanning => '正在扫描会话，可能需要一段时间...';

  @override
  String bookStatsScanningCount(int done, int total) {
    return '正在扫描会话，已完成 $done / $total 人...';
  }

  @override
  String bookStatsLastChecked(String when) {
    return '已于 $when 检查';
  }

  @override
  String get navHoldServerScan => '服务器扫描';

  @override
  String get navHoldScanAll => '扫描所有媒体库';

  @override
  String navHoldScanLibrary(String name) {
    return '扫描 $name';
  }

  @override
  String get navHoldScanStarted => '扫描已开始';

  @override
  String get navHoldScanFailed => '无法开始扫描';

  @override
  String get navHoldAdminLogs => '服务器日志';

  @override
  String navHoldAdminPage(String page) {
    return '管理后台: $page';
  }

  @override
  String get navHoldNothingPlaying => '还没有可播放的内容';

  @override
  String get navHoldReadBook => '阅读当前书籍';

  @override
  String get navHoldBookDetails => '当前书籍详情';

  @override
  String get syncSourceTitle => '同步应保留哪一份副本？';

  @override
  String get syncSourceBody =>
      '此备份开启了设置同步。使用服务器上次同步的内容，还是让此备份作为权威来源？选择此备份将用其覆盖服务器上的同步副本，影响您所有已同步的设备。';

  @override
  String get syncSourceUseServer => '服务器上次同步的内容';

  @override
  String get syncSourceUseBackup => '此备份';

  @override
  String get syncSettingsWhatTravels =>
      '会同步您的偏好设置、每本书的速度、首页布局、收听顺序、笔记和电子书划线。登录信息、下载文件夹、自动下载开关、阅读器外观以及任何尚未发送到服务器的内容仍保留在本设备上。';

  @override
  String get syncSettingsDownloadWarnTitle => '替换此设备的设置？';

  @override
  String get syncSettingsDownloadWarnBody => '同步副本将覆盖此设备上的设置。';

  @override
  String get syncSettingsDownloadWarnConfirm => '替换';

  @override
  String get readerCopied => '已复制到剪贴板';

  @override
  String get dictionaryNotFound => '未找到该词的定义。';

  @override
  String get dictionaryError => '无法访问词典。请检查您的连接。';

  @override
  String get dictionaryRetry => '重试';

  @override
  String get dictionarySearchWeb => '在网络上搜索';

  @override
  String get readerTooltipCopy => '复制';

  @override
  String get readerTooltipSearch => '搜索';

  @override
  String get readerTooltipDefine => '释义';

  @override
  String get readerSearchHint => '搜索本书…';

  @override
  String readerSearchMatches(int count, String query) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个“$query”匹配',
      one: '$count 个“$query”匹配',
    );
    return '$_temp0';
  }

  @override
  String get readerSearchEmpty => '输入一个单词或短语，然后点按搜索。';

  @override
  String readerSearchNoResults(String query) {
    return '没有与“$query”匹配的结果。';
  }

  @override
  String get transcriptionTitle => '转写';

  @override
  String get transcriptionAdvancedSubtitle => '用于转写书签，并在有声书和电子书之间定位';

  @override
  String get transcriptionEnable => '启用转写';

  @override
  String get transcriptionEnableSubtitle =>
      '为书签添加“转写”、为播放器添加“在电子书中查找位置”、为阅读器添加“在有声书中查找”';

  @override
  String get transcriptionDisclaimer =>
      '完全在您的设备上运行，不会上传任何内容。运行时会更耗电并占用处理能力，且只有已下载的书籍才能转写。';

  @override
  String get transcriptionNeedModelHint => '在下方下载模型即可开始转写。';

  @override
  String get transcriptionModelSection => '模型';

  @override
  String get transcriptionModelTiny => '微型';

  @override
  String get transcriptionModelTinyDesc => '最快，准确度较低。约 31 MB。';

  @override
  String get transcriptionModelBase => '基础';

  @override
  String get transcriptionModelBaseDesc => '兼顾速度与准确度的不错选择。约 57 MB。';

  @override
  String get transcriptionModelSmall => '小型';

  @override
  String get transcriptionModelSmallDesc => '较慢但最准确 - 在高性能手机上效果最佳。约 182 MB。';

  @override
  String get transcriptionAutoHint =>
      '下载多个模型后，每次转写任务会在其中自动选择。有电子书的书籍使用最快的模型，因为具体文字本来就取自电子书；没有电子书的则用最准确的 - 而“伴读”保持在小型以下，以便跟上朗读速度。';

  @override
  String get transcriptionDownload => '下载';

  @override
  String get transcriptionDownloadFailed => '下载失败。请检查您的连接后重试。';

  @override
  String get transcribe => '转写';

  @override
  String get transcribing => '正在转写...';

  @override
  String get transcriptionResultTitle => '转写文本';

  @override
  String get transcriptionSaveToNote => '保存到笔记';

  @override
  String get transcriptionSavedToNote => '已保存到书签笔记';

  @override
  String get transcriptionDisabledHint => '请在设置 > 高级中开启书签转写。';

  @override
  String get transcriptionNoModelDownloaded => '请先在设置中下载转写模型。';

  @override
  String get transcriptionNotDownloadedBook => '请先下载此书，再转写其书签。';

  @override
  String get transcriptionNoMetadataMsg => '无法在下载中定位此位置。请尝试重新下载这本书。';

  @override
  String get transcriptionBusyMsg => '已在转写其他内容。请稍等片刻。';

  @override
  String get transcriptionEmptyMsg => '此位置未检测到语音。';

  @override
  String get transcriptionFailedMsg => '无法转写此位置。请重试。';

  @override
  String get transcriptionPlaySnippet => '试听';

  @override
  String get transcriptionPauseSnippet => '暂停';

  @override
  String get transcriptionIntroBody =>
      '这会侦听从书签前开始的一小段音频，并在您的设备上将其转为文字。片段越长耗时越久，且转写并非 100% 准确。完成后文字会保存到书签的笔记中，方便整理或分享。';

  @override
  String get transcriptionUseEbookText => '在可匹配时使用电子书的精确文字';

  @override
  String get lyricsMode => '实时转录';

  @override
  String get lyricsListeningAhead => '正在向前侦听...';

  @override
  String get lyricsDisplaySection => '实时转录';

  @override
  String get lyricsFontSize => '行大小';

  @override
  String get lyricsMaxLines => '显示的行数';

  @override
  String get lyricsFullCover => '使用整张封面';

  @override
  String get lyricsFullCoverHint => '运行时在封面位置显示转录文本，能容纳多少行就显示多少行。';

  @override
  String get lyricsBatteryInfo => '实时转录和伴读运作时会更耗电并占用处理能力。在处理器较慢的手机上，行会显示得较慢。';

  @override
  String get lyricsClearCache => '清除转录缓存';

  @override
  String lyricsClearCacheHint(String size) {
    return '已保存 $size 的转录行。已清除的书籍和单集会在您收听时自动重新转录。';
  }

  @override
  String get lyricsClearCacheConfirm => '删除每本书和每个单集保存的转录？它们会在收听时自动重建。';

  @override
  String get lyricsCacheCleared => '转录缓存已清除';

  @override
  String get lyricsIntroBody =>
      '这会稍微超前侦听朗读内容，并在每句话说出的同时显示对应行，全程在您的手机上转写 - 不会有任何内容离开设备。启用后，先等一两秒再按播放，让它追上进度。转录文本会在其提前量就绪后出现，从暂停开始能获得最流畅的效果。运作时会更耗电并占用处理能力。';

  @override
  String lyricsBuildingLead(String percent) {
    return '正在跟上朗读进度... $percent';
  }

  @override
  String lyricsCantKeepUp(String speed) {
    return '无法以 $speed 的速度跟上您收听时的转录速度';
  }

  @override
  String get lyricsTurnOn => '开启';

  @override
  String get readAlong => '伴读';

  @override
  String get readAlongNeedsPlaying => '请先播放此书的有声书';

  @override
  String get transcriptionNeedsDownload => '这需要在手机上保存音频。现在就下载吗？';

  @override
  String get transcriptionDownloadStarted => '正在下载。完成后请重新开启此功能';

  @override
  String get readAlongFollow => '伴读跟随方式';

  @override
  String get readAlongFollowHint => '单词时间由转录时间戳推算得出，因此句内可能会有轻微偏差。';

  @override
  String get readAlongFollowWord => '单词';

  @override
  String get readAlongFollowSentence => '句子';

  @override
  String get readAlongColor => '伴读颜色';

  @override
  String get readAlongLost => '找不到页面上的朗读内容';

  @override
  String get readAlongReady => '伴读已就绪';

  @override
  String get findInEbook => '在电子书中查找';

  @override
  String get findInEbookSearching => '正在电子书中查找此位置...';

  @override
  String get findInEbookNotFound => '无法在电子书中找到此位置。';

  @override
  String get findInEbookNeedsEpub => '“在电子书中查找”需要 EPUB 格式的电子书。';

  @override
  String get findInEbookNoEbook => '这本书没有电子书。';

  @override
  String get findInAudiobook => '在有声书中查找';

  @override
  String get findInAudiobookSearching => '正在有声书中查找此位置...';

  @override
  String get findInAudiobookStillSearching => '仍在音频中搜索此位置...';

  @override
  String get findInAudiobookSearchingLong => '章节较长，仍在搜索中。可能需要一两分钟...';

  @override
  String get findInAudiobookNotFound => '无法在音频中找到此位置。';

  @override
  String get transcriptionWhisperInfo =>
      '转写由 Whisper 提供支持，这是一种开放语音识别模型，会侦听朗读内容并写出文字 - 一切都在本设备上完成。';

  @override
  String get transcriptionWhisperLearnMore => '了解关于 Whisper 的更多信息';

  @override
  String get findInAudiobookIntroBody =>
      '这会侦听您正在阅读位置附近的有声书内容，并在您的设备上将其与此段落进行匹配。可能需要最多一分钟。如果无法可靠找到该位置，则不会发生任何跳转。';

  @override
  String get findInAudiobookAfterLabel => '找到位置后';

  @override
  String get findInAudiobookStay => '继续阅读';

  @override
  String get findInAudiobookGoPlayer => '打开播放器';

  @override
  String get findInAudiobookPlaying => '正在有声书中播放此段落';

  @override
  String get recentSeries => '最近系列';

  @override
  String get newestAuthors => '最新作者';

  @override
  String get timeRemainingLessThanMinute => '剩余不足1分钟';

  @override
  String timeRemaining(String duration) {
    return '剩余 $duration';
  }

  @override
  String get historyEventResumed => '继续播放';

  @override
  String historyEventResumedDetail(String detail) {
    return '继续播放（$detail）';
  }

  @override
  String get historyEventPaused => '暂停';

  @override
  String historyEventPausedDetail(String detail) {
    return '暂停（$detail）';
  }

  @override
  String get historyEventSeeked => '跳转';

  @override
  String historyEventSeekedDetail(String detail) {
    return '跳转到 $detail';
  }

  @override
  String get historyEventSyncLocal => '保存到本地';

  @override
  String get historyEventSyncServer => '同步到服务器';

  @override
  String get historyEventAutoRewound => '自动回退';

  @override
  String historyEventAutoRewoundDetail(String detail) {
    return '自动回退 $detail';
  }

  @override
  String get historyEventSkipForward => '快进';

  @override
  String historyEventSkipForwardDetail(String detail) {
    return '快进 $detail';
  }

  @override
  String get historyEventSkipBack => '快退';

  @override
  String historyEventSkipBackDetail(String detail) {
    return '快退 $detail';
  }

  @override
  String get historyEventSpeedChanged => '语速已调整';

  @override
  String historyEventSpeedSetTo(String detail) {
    return '语速 $detail';
  }

  @override
  String get historyEventBookFinished => '整本听完';

  @override
  String get historyEventSessionStarted => '播放会话开始';

  @override
  String historyEventSessionStartedDetail(String detail) {
    return '播放会话开始（$detail）';
  }

  @override
  String get historyEventSessionEnded => '播放会话结束';

  @override
  String historyEventSessionEndedDetail(String detail) {
    return '播放会话结束（$detail）';
  }

  @override
  String get historyEventMediaButton => '媒体按钮';

  @override
  String historyEventMediaButtonDetail(String detail) {
    return '媒体按钮: $detail';
  }

  @override
  String historySeconds(String value) {
    return '$value秒';
  }

  @override
  String historyMinutes(String value) {
    return '$value分钟';
  }

  @override
  String historySpeed(String value) {
    return '$value倍速';
  }

  @override
  String get historyDetailStream => '流式播放';

  @override
  String get historyDetailStreamHotSwap => '流式切为本地播放';

  @override
  String get historyDetailSwitchedToLocal => '已切换到本地播放';

  @override
  String get historyDetailNextChapter => '跳到下一章';

  @override
  String get historyDetailPrevChapter => '跳到上一章';

  @override
  String get historyDetailNextChapterToEnd => '跳到书尾';

  @override
  String historyDetailNextChapterToIntroSkip(String position) {
    return '跳到下一章 $position（跳过片头）';
  }

  @override
  String historyDetailPrevChapterToIntroSkip(String position) {
    return '跳到上一章 $position（跳过片头）';
  }

  @override
  String get historyDetailSkipChapterIntro => '跳过章节片头';

  @override
  String get historyDetailSkipChapterOutro => '跳过章节片尾';

  @override
  String get historyDetailSkipToEnd => '跳到结尾';

  @override
  String get historyDetailSnapToChapterStart => '回到本章开头';

  @override
  String get historyDetailSessionStart => '会话开始';

  @override
  String get historyDetailSleepTimer => '睡眠定时器';

  @override
  String get historyDetailPlayAutoResumedInterruption => '中断后自动恢复播放';

  @override
  String get historyDetailPlayPageKey => '翻页键';

  @override
  String get historyDetailPlayReadAlongStopped => '跟读已停止';

  @override
  String get historyDetailPlayReadAlongReady => '跟读已就绪';

  @override
  String get historyDetailPauseOffline => '离线暂停';

  @override
  String get historyDetailPauseSpuriousBlocked => '已拦截误报的播放完成';

  @override
  String get historyDetailPauseIosPrematureBlocked => '已拦截 iOS 提前结束误报';

  @override
  String get historyDetailPrevChapterDirect => '跳转到上一章（直跳）';

  @override
  String historyDetailPrevChapterDirectToIntroSkip(String position) {
    return '跳转到上一章（直跳）$position（跳过片头）';
  }

  @override
  String get historyDetailLocalHotSwap => '本地热切换';

  @override
  String get historyDetailLocalSession => '本地会话';

  @override
  String get historyDetailRefresh => '刷新';

  @override
  String get historyDetailRecovery => '恢复会话';

  @override
  String get historyDetailStallRecovery => '卡顿恢复';

  @override
  String get historyDetailDeadSource => '数据源失效';

  @override
  String get historyDetailDirectFile => '直接文件播放';

  @override
  String get historyDetailBookFinished => '本书已播完';

  @override
  String get historyDetailLocalBookFinished => '本地文件已播完';

  @override
  String get historyDetailPauseTimeout => '暂停超时';

  @override
  String get historyDetailStop => '停止';

  @override
  String get historyDetailSeekSleepRewindUndone => '撤销睡眠回退';

  @override
  String historyDetailRewindAtSpeed(
    String base,
    String adjusted,
    String speed,
  ) {
    return '$base（$speed，对应 $adjusted）';
  }

  @override
  String historyDetailRewindSessionStart(String base) {
    return '$base（会话开始）';
  }

  @override
  String historyDetailRewindSessionStartAtSpeed(
    String base,
    String adjusted,
    String speed,
  ) {
    return '$base（$speed，对应 $adjusted，会话开始）';
  }

  @override
  String historyDetailRewindSleepTimer(String base) {
    return '$base（睡眠定时器）';
  }

  @override
  String historyDetailSkipForwardAtSpeed(
    String seconds,
    String adjusted,
    String speed,
  ) {
    return '$seconds（$speed，对应 $adjusted）';
  }

  @override
  String historyDetailSkipBackwardAtSpeed(
    String seconds,
    String adjusted,
    String speed,
  ) {
    return '$seconds（$speed，对应 $adjusted）';
  }

  @override
  String get playerErrorConnect => '连接不上服务器，请检查网络后重试';

  @override
  String get playerErrorNoAudio => '没有找到音频文件，服务器上可能已缺失这本书';

  @override
  String get playerErrorInit => '无法开始播放';

  @override
  String get playerErrorNotDownloadedOffline => '这本书还没下载，而且当前处于离线状态';

  @override
  String get playerErrorDownloadsMissing => '下载的文件不见了，请重新下载';

  @override
  String get playerErrorTranscodeStart => '无法开始转码播放';

  @override
  String get playerErrorTranscodeNoAudio => '转码后的会话里没有音频文件';

  @override
  String playerErrorGeneric(String error) {
    return '播放失败：$error';
  }
}
