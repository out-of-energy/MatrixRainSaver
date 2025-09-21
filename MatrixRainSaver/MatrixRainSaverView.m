#import "MatrixRainSaverView.h"

static NSString *const kDefaultsKeyCharsetMode = @"charset_mode"; // 0: 01, 1: ASCII, 2: Hex, 3: Base64
static NSInteger gCharsetMode = -1; // 进程内共享的当前模式，用于跨实例同步
static NSString *const kNotifyPrefsChanged = @"MatrixRainPrefsDidChange";

@implementation MatrixRainSaverView {
    NSFont *_font;
    CGFloat _charWidth;
    CGFloat _lineHeight;
    NSUInteger _columns;
    NSUInteger _rows;

    NSMutableArray<NSNumber *> *_headRows;    // 每列头部行
    NSMutableArray<NSNumber *> *_speeds;      // 每列速度（行/帧）
    NSMutableArray<NSNumber *> *_tailLens;    // 每列尾长
    NSMutableArray<NSNumber *> *_phaseOffsets; // 每列相位偏移（帧）
    NSMutableArray<NSNumber *> *_stepDividers; // 每列步进分频（减速）
    NSMutableArray<NSNumber *> *_restRemaining; // 每列剩余休止帧数
    NSMutableArray<NSNumber *> *_streamRemaining; // 每列当前雨线剩余步数（到0后进入休止）
    NSMutableArray<NSMutableArray<NSString *> *> *_columnChars; // 每列每行已固定字符

    NSDictionary *_attrsBright;               // 头部字符属性
    NSDictionary *_attrsHead2;                // 次头部字符属性（次亮）
    NSArray<NSDictionary *> *_attrsGradient;  // 渐变尾巴属性（从亮到暗）
    NSString *_charset;                       // 字符集（ASCII，避免字形回退）
    NSUInteger _globalFrame;                  // 全局帧计数
    NSInteger _activeMode;                    // 本实例当前已应用的模式
    // _isShowingSheet 已不再需要

    // 配置面板
    NSWindow *_configSheet;
    NSButton *_digitsRadio;    // 数字(01)
    NSButton *_lettersRadio;   // 字符(ASCII)
    NSButton *_hexRadio;       // 十六进制
    NSButton *_base64Radio;    // Base64
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self setAnimationTimeInterval:1/30.0];

        CGFloat fontSize = isPreview ? 12.0 : 18.0;
        _font = [NSFont fontWithName:@"Menlo" size:fontSize];
        if (!_font) {
            _font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
        }
        // 从偏好设置读取字符集模式，并保存到实例与全局
        [self loadDefaultsAndApplyCharset];

        // 监听分布式通知，保证“选项”面板改动可即时生效
        [[NSDistributedNotificationCenter defaultCenter] addObserver:self
                                                            selector:@selector(onPrefsChanged:)
                                                                name:kNotifyPrefsChanged
                                                              object:nil];

        [self buildMetrics];
        [self buildAttributes];
        [self rebuildGridForSize:frame.size];
    }
    return self;
}

- (void)dealloc {
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setCharsetForMode:(NSInteger)mode {
    switch (mode) {
        case 1: { // ASCII 33–126
            NSMutableString *ascii = [NSMutableString stringWithCapacity:(126 - 33 + 1)];
            for (unichar ch = 33; ch <= 126; ch++) {
                [ascii appendFormat:@"%C", ch];
            }
            _charset = ascii;
            break;
        }
        case 2: { // Hex
            _charset = @"0123456789ABCDEF";
            break;
        }
        case 3: { // Base64
            _charset = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            break;
        }
        default: { // 01
            _charset = @"01";
            break;
        }
    }
}

- (void)loadDefaultsAndApplyCharset {
    NSString *bundleId = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:bundleId];
    // 注册默认值
    NSDictionary *reg = @{ kDefaultsKeyCharsetMode : @(0) }; // 默认数字(01)
    [defaults registerDefaults:reg];

    NSInteger mode = [defaults integerForKey:kDefaultsKeyCharsetMode];
    [self setCharsetForMode:mode];
    _activeMode = mode;
    gCharsetMode = mode;
}

- (void)saveCharsetMode:(NSInteger)mode {
    NSString *bundleId = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:bundleId];
    [defaults setInteger:mode forKey:kDefaultsKeyCharsetMode];
    [defaults synchronize];
}

- (void)applyCharsetMode:(NSInteger)mode {
    // 先立即应用，避免依赖偏好读取导致的延迟或域问题
    [self setCharsetForMode:mode];
    _activeMode = mode;
    gCharsetMode = mode;
    [self saveCharsetMode:mode];
    [self rebuildGridForSize:self.bounds.size];
    [self setNeedsDisplay:YES];

    // 通知其他实例（预览/独立引擎）立刻应用
    NSString *bundleId = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    NSDictionary *info = @{ kDefaultsKeyCharsetMode : @(mode) };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:kNotifyPrefsChanged
                                                                       object:bundleId
                                                                     userInfo:info
                                                          deliverImmediately:YES];
    });
}

- (void)createConfigureSheetIfNeeded {
    if (!_configSheet) {
        NSRect frame = NSMakeRect(0, 0, 380, 230);
        _configSheet = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        _configSheet.title = @"设置";
        _configSheet.level = NSFloatingWindowLevel;

        NSView *content = _configSheet.contentView;

        NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 180, 200, 22)];
        label.bezeled = NO;
        label.drawsBackground = NO;
        label.editable = NO;
        label.selectable = NO;
        label.stringValue = @"字符集";
        [content addSubview:label];

        _digitsRadio = [[NSButton alloc] initWithFrame:NSMakeRect(40, 145, 240, 22)];
        _digitsRadio.buttonType = NSButtonTypeRadio;
        _digitsRadio.title = @"数字 (01)";
        _digitsRadio.target = self;
        _digitsRadio.action = @selector(onRadioChanged:);
        [content addSubview:_digitsRadio];

        _lettersRadio = [[NSButton alloc] initWithFrame:NSMakeRect(40, 120, 240, 22)];
        _lettersRadio.buttonType = NSButtonTypeRadio;
        _lettersRadio.title = @"字符 (ASCII 33–126)";
        _lettersRadio.target = self;
        _lettersRadio.action = @selector(onRadioChanged:);
        [content addSubview:_lettersRadio];

        _hexRadio = [[NSButton alloc] initWithFrame:NSMakeRect(40, 95, 240, 22)];
        _hexRadio.buttonType = NSButtonTypeRadio;
        _hexRadio.title = @"十六进制 (0–9, A–F)";
        _hexRadio.target = self;
        _hexRadio.action = @selector(onRadioChanged:);
        [content addSubview:_hexRadio];

        _base64Radio = [[NSButton alloc] initWithFrame:NSMakeRect(40, 70, 240, 22)];
        _base64Radio.buttonType = NSButtonTypeRadio;
        _base64Radio.title = @"Base64 (A–Z, a–z, 0–9, +, /)";
        _base64Radio.target = self;
        _base64Radio.action = @selector(onRadioChanged:);
        [content addSubview:_base64Radio];

        NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(270, 20, 80, 30)];
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.title = @"完成";
        closeBtn.target = self;
        closeBtn.action = @selector(onClose:);
        [content addSubview:closeBtn];

        // 初始化状态
        NSString *bundleId = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
        ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:bundleId];
        NSInteger mode = [defaults integerForKey:kDefaultsKeyCharsetMode];
        _digitsRadio.state = (mode == 0) ? NSControlStateValueOn : NSControlStateValueOff;
        _lettersRadio.state = (mode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
        _hexRadio.state = (mode == 2) ? NSControlStateValueOn : NSControlStateValueOff;
        _base64Radio.state = (mode == 3) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)onRadioChanged:(id)sender {
    // 始终响应，避免因窗口状态导致忽略
    NSInteger mode = 0;
    if (sender == _lettersRadio) mode = 1;
    else if (sender == _hexRadio) mode = 2;
    else if (sender == _base64Radio) mode = 3;
    else mode = 0;

    // 避免重复重建导致宿主频繁触发 configureSheet
    if (mode == _activeMode) return;
    [self applyCharsetMode:mode];

    // 同步 UI 勾选
    _digitsRadio.state = (mode == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _lettersRadio.state = (mode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _hexRadio.state = (mode == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    _base64Radio.state = (mode == 3) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)onClose:(id)sender {
    // 读取当前勾选并应用
    NSInteger mode = 0;
    if (_lettersRadio.state == NSControlStateValueOn) mode = 1;
    else if (_hexRadio.state == NSControlStateValueOn) mode = 2;
    else if (_base64Radio.state == NSControlStateValueOn) mode = 3;
    else mode = 0;
    if (mode != _activeMode) {
        [self applyCharsetMode:mode];
    }
    if (_configSheet.sheetParent) {
        [NSApp endSheet:_configSheet];
    }
    [_configSheet orderOut:nil];
}

- (void)onPrefsChanged:(NSNotification *)note {
    // 读取持久化并应用
    [self loadDefaultsAndApplyCharset];
    [self rebuildGridForSize:self.bounds.size];
    [self setNeedsDisplay:YES];
}


- (void)startAnimation {
    [super startAnimation];
    // 如果系统重新创建了新实例，尝试用进程级缓存同步模式
    if (gCharsetMode >= 0 && gCharsetMode != _activeMode) {
        [self setCharsetForMode:gCharsetMode];
        _activeMode = gCharsetMode;
        [self rebuildGridForSize:self.bounds.size];
        [self setNeedsDisplay:YES];
    }
}

- (void)stopAnimation {
    [super stopAnimation];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self buildMetrics];
    [self rebuildGridForSize:newSize];
}

- (void)buildMetrics {
    NSDictionary *attrs = @{ NSFontAttributeName : _font };
    CGFloat baseCharWidth = ceil([@"0" sizeWithAttributes:attrs].width);
    // 增加一个字符宽度的间距，让列不那么密集
    _charWidth = baseCharWidth * 2.0;
    NSLog(@"Matrix: baseCharWidth=%.1f, _charWidth=%.1f", baseCharWidth, _charWidth);
    // Compute line height from font metrics to avoid relying on unavailable class methods
    CGFloat ascender = _font.ascender;
    CGFloat descender = -_font.descender; // descender is negative
    CGFloat leading = _font.leading;
    _lineHeight = ceil(ascender + descender + leading);
    if (_charWidth < 1.0) _charWidth = 20.0; // 相应调整最小值
    if (_lineHeight < 1.0) _lineHeight = 16.0;
}

- (void)buildAttributes {
    // 明亮头部：偏白的荧光绿
    _attrsBright = @{
        NSFontAttributeName : _font,
        NSForegroundColorAttributeName : [NSColor colorWithRed:0.95 green:1.0 blue:0.95 alpha:1.0]
    };
    // 次亮：纯绿更亮，放在头部的下一位
    _attrsHead2 = @{
        NSFontAttributeName : _font,
        NSForegroundColorAttributeName : [NSColor colorWithRed:0.4 green:1.0 blue:0.4 alpha:0.95]
    };
    // 尾巴渐变（32 级，更细腻）
    NSInteger steps = 32;
    NSMutableArray *grad = [NSMutableArray arrayWithCapacity:(NSUInteger)steps];
    for (NSInteger i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)steps;      // 0→1
        CGFloat alpha = 0.85 * (1.0 - t) + 0.08;      // 0.08→0.85
        NSColor *c = [NSColor colorWithRed:0.0 green:1.0 blue:0.0 alpha:alpha];
        [grad addObject:@{ NSFontAttributeName : _font, NSForegroundColorAttributeName : c }];
    }
    _attrsGradient = grad;
}

- (void)rebuildGridForSize:(NSSize)size {
    _columns = (NSUInteger)MAX(1, floor(size.width / _charWidth));
    _rows    = (NSUInteger)MAX(1, floor(size.height / _lineHeight));

    _headRows = [NSMutableArray arrayWithCapacity:_columns];
    _speeds   = [NSMutableArray arrayWithCapacity:_columns];
    _tailLens = [NSMutableArray arrayWithCapacity:_columns];
    _phaseOffsets = [NSMutableArray arrayWithCapacity:_columns];
    _stepDividers = [NSMutableArray arrayWithCapacity:_columns];
    _restRemaining = [NSMutableArray arrayWithCapacity:_columns];
    _streamRemaining = [NSMutableArray arrayWithCapacity:_columns];
    _columnChars = [NSMutableArray arrayWithCapacity:_columns];
    _globalFrame = 0;

    for (NSUInteger c = 0; c < _columns; c++) {
        NSUInteger head = 0; // spawn at top row
        // cmatrix-like：多数列 1 行/步，部分列 2 行/步；步进分频 1–3 帧/步
        NSUInteger speed = 1; // 固定为 1 行/步，去除过快的列
        NSUInteger tail  = 12 + arc4random_uniform(24);    // 12~35，更长更随机
        NSUInteger phase = arc4random_uniform(90);
        [_headRows addObject:@(head)];
        [_speeds addObject:@(speed)];
        [_tailLens addObject:@(tail)];
        [_phaseOffsets addObject:@(phase)];
        NSUInteger divider = (12 + arc4random_uniform(9)); // 12–20 帧/步，更慢
        [_stepDividers addObject:@(divider)];
        [_restRemaining addObject:@(0)];
        // 目标长度随机，但初始可见长度从 1 开始，避免突兀
        [_streamRemaining addObject:@(10 + arc4random_uniform(80))]; // 目标长度

        // 初始化每列字符缓存
        NSMutableArray<NSString *> *colChars = [NSMutableArray arrayWithCapacity:_rows];
        for (NSUInteger r = 0; r < _rows; r++) {
            // 预填充一个字符，后续仅在 head 位置更新
            unichar ch = [self randomChar];
            NSString *s = [NSString stringWithCharacters:&ch length:1];
            [colChars addObject:s];
        }
        _columnChars[c] = colChars;
    }
}

- (unichar)randomChar {
    if (_charset.length == 0) return '0';
    u_int32_t idx = arc4random_uniform((u_int32_t)_charset.length);
    return [_charset characterAtIndex:idx];
}

- (void)drawRect:(NSRect)rect {
    // 背景清屏
    [[NSColor blackColor] setFill];
    NSRectFill(rect);

    // 绘制每列：头部 + 渐变尾巴
    for (NSUInteger col = 0; col < _columns; col++) {
        NSUInteger head = [_headRows[col] unsignedIntegerValue];
        NSUInteger tailLen = [_tailLens[col] unsignedIntegerValue];
        // 在靠近顶部时限制可见尾长，避免首帧就出现很长的尾巴
        NSUInteger visibleTail = MIN(tailLen, head + 1);

        for (NSUInteger k = 0; k <= visibleTail; k++) {
            NSInteger row = (NSInteger)head - (NSInteger)k;
            if (row < 0 || row >= (NSInteger)_rows) {
                continue; // do not wrap; clip off-screen
            }

            CGFloat px = round((CGFloat)col * _charWidth);
            CGFloat py = round(((CGFloat)_rows - (CGFloat)row - 1.0) * _lineHeight);
            NSPoint p = NSMakePoint(px, py);
            NSMutableArray<NSString *> *colChars = _columnChars[col];
            NSString *s = (row < (NSInteger)colChars.count) ? colChars[(NSUInteger)row] : @"0";
            // 只使用已缓存的字符，不在绘制时生成新字符，避免闪烁

            NSDictionary *attr;
            if (k == 0) {
                attr = _attrsBright;
            } else if (k == 1) {
                attr = _attrsHead2;
            } else {
                NSUInteger idx = MIN((NSUInteger)(k - 1), _attrsGradient.count - 1);
                attr = _attrsGradient[idx];
            }

            [s drawAtPoint:p withAttributes:attr];
        }
    }
}

- (void)animateOneFrame {
    _globalFrame++;
    // 更新列头位置（分频、相位、休止、雨线长度控制，字符仅在 head 更新）
    for (NSUInteger col = 0; col < _columns; col++) {
        // 不再使用休止期，保持持续流动
        _restRemaining[col] = @(0);

        NSUInteger streamLeft = [_streamRemaining[col] unsignedIntegerValue];
        if (streamLeft == 0) {
            // 开启新一段雨线
            _tailLens[col] = @(12 + arc4random_uniform(24)); // 12~35（目标长度）
            NSUInteger divider = (12 + arc4random_uniform(9)); // 12–20 帧/步，更慢
            _stepDividers[col] = @(divider);
            _phaseOffsets[col] = @(arc4random_uniform(90));
            _speeds[col] = @(1); // 保持 speed=1，避免过快
            NSUInteger newHead = 0; // start new stream at top row
            _headRows[col] = @(newHead);
            // 在新 head 位置生成一个新字符（始终设置，确保可见）
            unichar ch0 = [self randomChar];
            NSString *s0 = [NSString stringWithCharacters:&ch0 length:1];
            _columnChars[col][(NSUInteger)newHead] = s0;
            _streamRemaining[col] = @(15 + arc4random_uniform(80)); // 目标长度
            continue;
        }

        NSUInteger divider = [_stepDividers[col] unsignedIntegerValue];

        // 步进（考虑相位）
        if ((_globalFrame + [_phaseOffsets[col] unsignedIntegerValue]) % divider == 0) {
            
            if (col == 0 && _globalFrame % 60 == 0) { // 每秒打印一次第0列的状态用于调试
                NSLog(@"[MatrixRain] Col 0: divider=%lu, speed=%lu", (unsigned long)divider, (unsigned long)1);
            }

            // --- 移动头部 ---
            NSUInteger head = [_headRows[col] unsignedIntegerValue];
            NSUInteger newHead = (head + 1);

            if (newHead >= _rows) {
                // 到达底部：用几帧把尾巴缩短到 0，再重启
                NSUInteger tl = [_tailLens[col] unsignedIntegerValue];
                if (tl > 0) {
                    _tailLens[col] = @(tl > 3 ? tl - 3 : 0);
                    // 不推进 head，等待下一帧继续衰减
                    continue;
                }
                _streamRemaining[col] = @(0);
                _restRemaining[col] = @(0);
                continue;
            }
            _headRows[col] = @(newHead);
            // 更新新 head 位置的字符，避免空白
            unichar ch = [self randomChar];
            NSString *s = [NSString stringWithCharacters:&ch length:1];
            _columnChars[col][(NSUInteger)newHead] = s;
            // 雨线推进一次
            streamLeft--;
            _streamRemaining[col] = @(streamLeft);
            if (streamLeft == 0) {
                // 不休止，下一帧在顶部立即重启
                _restRemaining[col] = @(0);
            }
        }
    }
    [self setNeedsDisplay:YES];
}

- (BOOL)hasConfigureSheet {
    return YES;
}

- (NSWindow *)configureSheet {
    if (!_configSheet) {
        [self createConfigureSheetIfNeeded];
    }
    // 每次弹出前同步一次默认值到 UI
    NSString *bundleId = [[NSBundle bundleForClass:[self class]] bundleIdentifier];
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:bundleId];
    NSInteger mode = [defaults integerForKey:kDefaultsKeyCharsetMode];
    _digitsRadio.state = (mode == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    _lettersRadio.state = (mode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _hexRadio.state = (mode == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    _base64Radio.state = (mode == 3) ? NSControlStateValueOn : NSControlStateValueOff;
    
    // 居中显示窗口
    [_configSheet center];
    [_configSheet makeKeyAndOrderFront:nil];
    
    return _configSheet;
}

@end