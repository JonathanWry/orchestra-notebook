#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <PDFKit/PDFKit.h>

static BOOL IsScoreURL(NSURL *url) {
    if (!url.isFileURL) return NO;
    NSString *extension = url.pathExtension.lowercaseString;
    return [@[@"mscz", @"mscx"] containsObject:extension];
}

static NSArray<NSString *> *MuseScoreSessionPaths(void) {
    NSURL *sessionURL = [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MuseScore/MuseScore4/session/session.json"]];
    NSData *data = [NSData dataWithContentsOfURL:sessionURL];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [object isKindOfClass:NSArray.class] ? object : @[];
}

static NSString *ResolveMuseScorePath(NSDictionary *selection) {
    NSString *provided = selection[@"scorePath"];
    if (provided.length && [NSFileManager.defaultManager fileExistsAtPath:provided]) return provided;
    NSArray<NSString *> *paths = MuseScoreSessionPaths();
    NSString *title = selection[@"scoreTitle"];
    for (NSString *path in paths.reverseObjectEnumerator) {
        NSString *basename = path.lastPathComponent.stringByDeletingPathExtension;
        if (title.length && [basename isEqualToString:title] && [NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    }
    for (NSString *path in paths.reverseObjectEnumerator) if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
    return nil;
}

static NSData *RunTask(NSString *executable, NSArray<NSString *> *arguments, NSError **outError) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    NSPipe *output = [NSPipe pipe];
    NSPipe *errors = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = errors;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) *outError = launchError;
        return nil;
    }
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    NSData *errorData = [errors.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        NSString *message = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
        if (outError) *outError = [NSError errorWithDomain:@"OrchestraNotebook" code:task.terminationStatus userInfo:@{
            NSLocalizedDescriptionKey: message.length ? message : @"读取压缩乐谱失败"
        }];
        return nil;
    }
    return data;
}

static NSString *InstrumentGroup(NSString *instrumentID, NSString *name) {
    NSString *value = [[NSString stringWithFormat:@"%@ %@", instrumentID ?: @"", name ?: @""] lowercaseString];
    NSArray *tests = @[
        @[@"木管", @[@"flute", @"piccolo", @"oboe", @"clarinet", @"bassoon", @"saxophone", @"recorder", @"wind."]],
        @[@"铜管", @[@"trumpet", @"horn", @"trombone", @"tuba", @"euphonium", @"cornet", @"brass"]],
        @[@"打击乐", @[@"percussion", @"drum", @"cymbal", @"timpani", @"marimba", @"xylophone", @"glock", @"bells", @"tambourine"]],
        @[@"弦乐", @[@"violin", @"viola", @"cello", @"contrabass", @"double-bass", @"strings"]],
        @[@"键盘 / 竖琴", @[@"piano", @"keyboard", @"harp", @"organ", @"celesta"]],
        @[@"人声", @[@"voice", @"vocal", @"choir", @"soprano", @"alto", @"tenor", @"baritone"]]
    ];
    for (NSArray *test in tests) {
        for (NSString *needle in test[1]) if ([value containsString:needle]) return test[0];
    }
    return @"其他";
}

@interface ScoreXMLParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSString *> *stack;
@property(nonatomic, strong) NSMutableString *text;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *parts;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *staffToPart;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *measureIndexes;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *markers;
@property(nonatomic, strong) NSMutableDictionary *currentPart;
@property(nonatomic, copy) NSString *currentStaffID;
@property(nonatomic, strong) NSMutableDictionary *currentMeasure;
@property(nonatomic, copy) NSString *metaName;
@property(nonatomic) BOOL inPart;
@property(nonatomic) BOOL inDynamic;
@property(nonatomic) BOOL inMarker;
@property(nonatomic) BOOL inTempo;
@property(nonatomic) BOOL inLayoutBreak;
@property(nonatomic, copy) NSString *markerText;
@property(nonatomic, copy) NSString *layoutSubtype;
@property(nonatomic) NSInteger measureCount;
@property(nonatomic) NSInteger pageNumber;
@property(nonatomic, copy) NSString *firstScoreStaffID;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *composer;
@property(nonatomic, copy) NSString *subtitle;
@end

@implementation ScoreXMLParser

- (instancetype)init {
    if ((self = [super init])) {
        _stack = [NSMutableArray array];
        _text = [NSMutableString string];
        _parts = [NSMutableArray array];
        _staffToPart = [NSMutableDictionary dictionary];
        _measureIndexes = [NSMutableDictionary dictionary];
        _markers = [NSMutableArray array];
        _pageNumber = 1;
    }
    return self;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    NSString *parent = self.stack.lastObject;
    [self.stack addObject:element];
    [self.text setString:@""];

    if ([element isEqualToString:@"Part"] && [parent isEqualToString:@"Score"]) {
        self.inPart = YES;
        self.currentPart = [@{
            @"id": attributes[@"id"] ?: [NSString stringWithFormat:@"part-%lu", (unsigned long)self.parts.count + 1],
            @"staffIds": [NSMutableArray array],
            @"activityMap": [NSMutableDictionary dictionary]
        } mutableCopy];
    } else if ([element isEqualToString:@"Staff"]) {
        NSString *staffID = attributes[@"id"] ?: @"";
        if (self.inPart) {
            if (staffID.length) [self.currentPart[@"staffIds"] addObject:staffID];
        } else if ([parent isEqualToString:@"Score"]) {
            self.currentStaffID = staffID;
            if (!self.firstScoreStaffID.length) self.firstScoreStaffID = staffID;
        }
    } else if ([element isEqualToString:@"Measure"] && self.currentStaffID.length) {
        NSInteger index = [self.measureIndexes[self.currentStaffID] integerValue] + 1;
        self.measureIndexes[self.currentStaffID] = @(index);
        self.measureCount = MAX(self.measureCount, index);
        self.currentMeasure = [@{
            @"measure": @(index), @"chords": @0, @"notes": @0,
            @"minPitch": @127, @"maxPitch": @0, @"dynamic": @""
        } mutableCopy];
    } else if ([element isEqualToString:@"Chord"] && self.currentMeasure) {
        self.currentMeasure[@"chords"] = @([self.currentMeasure[@"chords"] integerValue] + 1);
    } else if ([element isEqualToString:@"Note"] && self.currentMeasure) {
        self.currentMeasure[@"notes"] = @([self.currentMeasure[@"notes"] integerValue] + 1);
    } else if ([element isEqualToString:@"Dynamic"] && self.currentMeasure) {
        self.inDynamic = YES;
    } else if ([element isEqualToString:@"RehearsalMark"] && [self.currentStaffID isEqualToString:self.firstScoreStaffID]) {
        self.inMarker = YES;
        self.markerText = @"";
    } else if ([element isEqualToString:@"Tempo"] && [self.currentStaffID isEqualToString:self.firstScoreStaffID]) {
        self.inTempo = YES;
    } else if ([element isEqualToString:@"LayoutBreak"] && [self.currentStaffID isEqualToString:self.firstScoreStaffID]) {
        self.inLayoutBreak = YES;
        self.layoutSubtype = @"";
    } else if ([element isEqualToString:@"metaTag"]) {
        self.metaName = attributes[@"name"];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.text appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    NSString *value = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *parent = self.stack.count >= 2 ? self.stack[self.stack.count - 2] : @"";

    if (self.currentPart) {
        if ([element isEqualToString:@"trackName"] && [parent isEqualToString:@"Part"] && value.length) self.currentPart[@"trackName"] = value;
        if ([element isEqualToString:@"longName"] && value.length && !self.currentPart[@"longName"]) self.currentPart[@"longName"] = value;
        if ([element isEqualToString:@"shortName"] && value.length && !self.currentPart[@"shortName"]) self.currentPart[@"shortName"] = value;
        if ([element isEqualToString:@"instrumentId"] && value.length && !self.currentPart[@"instrumentId"]) self.currentPart[@"instrumentId"] = value;
    }
    if ([element isEqualToString:@"pitch"] && self.currentMeasure && value.length) {
        NSInteger pitch = value.integerValue;
        self.currentMeasure[@"minPitch"] = @(MIN([self.currentMeasure[@"minPitch"] integerValue], pitch));
        self.currentMeasure[@"maxPitch"] = @(MAX([self.currentMeasure[@"maxPitch"] integerValue], pitch));
    }
    if ([element isEqualToString:@"subtype"]) {
        if (self.inDynamic && value.length) self.currentMeasure[@"dynamic"] = value;
        if (self.inLayoutBreak && value.length) self.layoutSubtype = value;
    }
    if ([element isEqualToString:@"text"] && self.inMarker && value.length) self.markerText = value;
    if ([element isEqualToString:@"tempo"] && self.inTempo && value.length && self.currentMeasure) {
        double bpm = value.doubleValue * 60.0;
        if (bpm > 0) [self.markers addObject:[@{@"measure": self.currentMeasure[@"measure"], @"text": [NSString stringWithFormat:@"♩ = %.0f", bpm], @"type": @"tempo"} mutableCopy]];
    }
    if ([element isEqualToString:@"metaTag"]) {
        if ([self.metaName isEqualToString:@"workTitle"] && value.length) self.title = value;
        else if ([self.metaName isEqualToString:@"composer"] && value.length) self.composer = value;
        else if ([self.metaName isEqualToString:@"subtitle"] && value.length) self.subtitle = value;
        self.metaName = nil;
    }
    if ([element isEqualToString:@"Dynamic"]) self.inDynamic = NO;
    if ([element isEqualToString:@"Tempo"]) self.inTempo = NO;
    if ([element isEqualToString:@"RehearsalMark"]) {
        if (self.markerText.length && self.currentMeasure) [self.markers addObject:[@{@"measure": self.currentMeasure[@"measure"], @"text": self.markerText, @"type": @"rehearsal"} mutableCopy]];
        self.inMarker = NO;
    }
    if ([element isEqualToString:@"LayoutBreak"]) {
        if ([self.layoutSubtype isEqualToString:@"page"] && self.currentMeasure) {
            [self.markers addObject:[@{@"measure": self.currentMeasure[@"measure"], @"text": [NSString stringWithFormat:@"第 %ld 页起", (long)self.pageNumber + 1], @"type": @"page"} mutableCopy]];
            self.pageNumber += 1;
        }
        self.inLayoutBreak = NO;
    }
    if ([element isEqualToString:@"Measure"] && self.currentMeasure) {
        NSMutableDictionary *part = self.staffToPart[self.currentStaffID];
        NSInteger notes = [self.currentMeasure[@"notes"] integerValue];
        NSInteger chords = [self.currentMeasure[@"chords"] integerValue];
        NSString *dynamic = self.currentMeasure[@"dynamic"];
        if (part && (notes > 0 || chords > 0 || dynamic.length > 0)) {
            NSString *key = [self.currentMeasure[@"measure"] stringValue];
            NSMutableDictionary *map = part[@"activityMap"];
            NSMutableDictionary *activity = map[key];
            if (!activity) activity = [self.currentMeasure mutableCopy];
            else {
                activity[@"notes"] = @([activity[@"notes"] integerValue] + notes);
                activity[@"chords"] = @([activity[@"chords"] integerValue] + chords);
                activity[@"minPitch"] = @(MIN([activity[@"minPitch"] integerValue], [self.currentMeasure[@"minPitch"] integerValue]));
                activity[@"maxPitch"] = @(MAX([activity[@"maxPitch"] integerValue], [self.currentMeasure[@"maxPitch"] integerValue]));
                if (dynamic.length) activity[@"dynamic"] = dynamic;
            }
            map[key] = activity;
        }
        self.currentMeasure = nil;
    }
    if ([element isEqualToString:@"Part"] && self.currentPart) {
        NSString *name = self.currentPart[@"longName"] ?: self.currentPart[@"trackName"] ?: self.currentPart[@"shortName"] ?: @"未命名乐器";
        self.currentPart[@"name"] = name;
        self.currentPart[@"group"] = InstrumentGroup(self.currentPart[@"instrumentId"], name);
        for (NSString *staffID in self.currentPart[@"staffIds"]) self.staffToPart[staffID] = self.currentPart;
        [self.parts addObject:self.currentPart];
        self.currentPart = nil;
        self.inPart = NO;
    }
    if ([element isEqualToString:@"Staff"] && !self.inPart && self.currentStaffID.length) self.currentStaffID = nil;

    if (self.stack.count) [self.stack removeLastObject];
    [self.text setString:@""];
}

- (NSDictionary *)resultForURL:(NSURL *)url thumbnailData:(NSData *)thumbnailData {
    NSMutableArray *cleanParts = [NSMutableArray array];
    for (NSMutableDictionary *part in self.parts) {
        NSDictionary *map = part[@"activityMap"] ?: @{};
        NSArray *keys = [map.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [@(a.integerValue) compare:@(b.integerValue)];
        }];
        NSMutableArray *activities = [NSMutableArray array];
        NSInteger maxNotes = 1;
        for (NSString *key in keys) maxNotes = MAX(maxNotes, [map[key][@"notes"] integerValue]);
        for (NSString *key in keys) {
            NSMutableDictionary *item = [map[key] mutableCopy];
            item[@"density"] = @(MIN(1.0, 0.18 + 0.82 * [item[@"notes"] doubleValue] / maxNotes));
            if ([item[@"minPitch"] integerValue] >= 127) [item removeObjectForKey:@"minPitch"];
            [activities addObject:item];
        }
        NSMutableDictionary *clean = [part mutableCopy];
        [clean removeObjectForKey:@"activityMap"];
        [clean removeObjectForKey:@"staffIds"];
        clean[@"activities"] = activities;
        [cleanParts addObject:clean];
    }
    NSString *fallback = url.lastPathComponent.stringByDeletingPathExtension;
    NSMutableDictionary *result = [@{
        @"id": url.path,
        @"path": url.path,
        @"title": self.title.length ? self.title : fallback,
        @"composer": self.composer ?: @"",
        @"subtitle": self.subtitle ?: @"",
        @"measureCount": @(self.measureCount),
        @"pageCount": @(MAX(1, self.pageNumber)),
        @"parts": cleanParts,
        @"markers": self.markers
    } mutableCopy];
    if (thumbnailData.length) result[@"thumbnail"] = [NSString stringWithFormat:@"data:image/png;base64,%@", [thumbnailData base64EncodedStringWithOptions:0]];
    return result;
}

@end

static NSDictionary *ParseScoreURL(NSURL *url, NSError **outError) {
    NSData *xmlData = nil;
    NSData *thumbnailData = nil;
    if ([url.pathExtension.lowercaseString isEqualToString:@"mscx"]) {
        xmlData = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:outError];
    } else {
        NSData *listingData = RunTask(@"/usr/bin/unzip", @[@"-Z1", url.path], outError);
        if (!listingData) return nil;
        NSString *listing = [[NSString alloc] initWithData:listingData encoding:NSUTF8StringEncoding] ?: @"";
        NSString *scoreEntry = nil;
        NSString *thumbnailEntry = nil;
        for (NSString *line in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (!scoreEntry && [line.pathExtension.lowercaseString isEqualToString:@"mscx"] && ![line containsString:@"/"]) scoreEntry = line;
            if (!thumbnailEntry && [line.lowercaseString hasSuffix:@"thumbnail.png"] && [line containsString:@"Thumbnails/"]) thumbnailEntry = line;
        }
        if (!scoreEntry.length) {
            if (outError) *outError = [NSError errorWithDomain:@"OrchestraNotebook" code:2 userInfo:@{NSLocalizedDescriptionKey: @"MSCZ 中没有找到主乐谱 XML"}];
            return nil;
        }
        xmlData = RunTask(@"/usr/bin/unzip", @[@"-p", url.path, scoreEntry], outError);
        if (thumbnailEntry.length) thumbnailData = RunTask(@"/usr/bin/unzip", @[@"-p", url.path, thumbnailEntry], nil);
    }
    if (!xmlData.length) return nil;
    ScoreXMLParser *delegate = [ScoreXMLParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:xmlData];
    parser.delegate = delegate;
    if (![parser parse]) {
        if (outError) *outError = parser.parserError;
        return nil;
    }
    return [delegate resultForURL:url thumbnailData:thumbnailData];
}

@interface MeasurePositionParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *positions;
@end

@implementation MeasurePositionParser
- (instancetype)init { if ((self = [super init])) _positions = [NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributes {
    if (![element isEqualToString:@"element"] || !attributes[@"id"]) return;
    [self.positions addObject:@{
        @"id": @([attributes[@"id"] integerValue]), @"page": @([attributes[@"page"] integerValue]),
        @"x": @([attributes[@"x"] doubleValue]), @"y": @([attributes[@"y"] doubleValue]),
        @"sx": @([attributes[@"sx"] doubleValue]), @"sy": @([attributes[@"sy"] doubleValue])
    }];
}
@end

static NSData *PNGDataForSelection(NSDictionary *selection, NSError **outError) {
    NSString *scorePath = selection[@"scorePath"];
    NSString *museScore = @"/Applications/MuseScore 4.app/Contents/MacOS/mscore";
    if (!scorePath.length || ![NSFileManager.defaultManager fileExistsAtPath:scorePath] || ![NSFileManager.defaultManager fileExistsAtPath:museScore]) {
        if (outError) *outError = [NSError errorWithDomain:@"OrchestraNotebook" code:10 userInfo:@{NSLocalizedDescriptionKey:@"找不到乐谱或 MuseScore 渲染程序"}];
        return nil;
    }
    NSURL *folder = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"orchestra-snippet-%@", NSUUID.UUID.UUIDString]] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *pngBase = [folder URLByAppendingPathComponent:@"page.png"];
    NSURL *mposURL = [folder URLByAppendingPathComponent:@"score.mpos"];
    NSError *taskError = nil;
    RunTask(museScore, @[@"-o", pngBase.path, scorePath], &taskError);
    NSURL *firstRenderedPage = [folder URLByAppendingPathComponent:@"page-1.png"];
    BOOL hasRenderedPage = [NSFileManager.defaultManager fileExistsAtPath:pngBase.path] || [NSFileManager.defaultManager fileExistsAtPath:firstRenderedPage.path];
    RunTask(museScore, @[@"-o", mposURL.path, scorePath], &taskError);
    if (!hasRenderedPage || ![NSFileManager.defaultManager fileExistsAtPath:mposURL.path]) {
        if (outError) *outError = taskError;
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        return nil;
    }
    NSData *mposData = [NSData dataWithContentsOfURL:mposURL];
    MeasurePositionParser *delegate = [MeasurePositionParser new];
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:mposData ?: NSData.data];
    parser.delegate = delegate;
    if (![parser parse]) {
        if (outError) *outError = parser.parserError;
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        return nil;
    }
    NSInteger firstID = MAX(0, [selection[@"startMeasure"] integerValue] - 1);
    NSInteger lastID = MAX(firstID, [selection[@"endMeasure"] integerValue] - 1);
    NSMutableArray<NSDictionary *> *chosen = [NSMutableArray array];
    for (NSDictionary *position in delegate.positions) {
        NSInteger identifier = [position[@"id"] integerValue];
        if (identifier >= firstID && identifier <= lastID) [chosen addObject:position];
    }
    if (!chosen.count) {
        if (outError) *outError = [NSError errorWithDomain:@"OrchestraNotebook" code:11 userInfo:@{NSLocalizedDescriptionKey:@"无法在渲染结果中定位这些小节"}];
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        return nil;
    }
    [chosen sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult page = [a[@"page"] compare:b[@"page"]];
        if (page != NSOrderedSame) return page;
        NSComparisonResult y = [a[@"y"] compare:b[@"y"]];
        return y != NSOrderedSame ? y : [a[@"x"] compare:b[@"x"]];
    }];
    NSMutableArray<NSMutableDictionary *> *systems = [NSMutableArray array];
    for (NSDictionary *position in chosen) {
        NSMutableDictionary *system = systems.lastObject;
        BOOL sameSystem = system && [system[@"page"] integerValue] == [position[@"page"] integerValue] && fabs([system[@"y"] doubleValue] - [position[@"y"] doubleValue]) < 20.0;
        if (!sameSystem) {
            system = [@{@"page":position[@"page"], @"y":position[@"y"], @"sy":position[@"sy"], @"items":[NSMutableArray array]} mutableCopy];
            [systems addObject:system];
        }
        [system[@"items"] addObject:position];
    }
    NSInteger staffCount = MAX(1, [selection[@"staffCount"] integerValue]);
    NSInteger firstStaff = MAX(0, MIN(staffCount - 1, [selection[@"startStaff"] integerValue]));
    NSInteger endStaff = [selection[@"endStaff"] integerValue];
    if (endStaff <= firstStaff) endStaff = firstStaff + 1;
    endStaff = MIN(staffCount, endStaff);
    NSMutableArray<NSImage *> *slices = [NSMutableArray array];
    CGFloat targetWidth = 0, targetHeight = 0;
    for (NSDictionary *system in systems) {
        NSInteger page = [system[@"page"] integerValue];
        NSURL *pageURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"page-%ld.png", (long)page + 1]];
        if (![NSFileManager.defaultManager fileExistsAtPath:pageURL.path]) pageURL = pngBase;
        CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)pageURL, NULL);
        NSDictionary *properties = imageSource ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL)) : nil;
        if (imageSource) CFRelease(imageSource);
        CGFloat originalWidth = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        CGFloat originalHeight = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        NSURL *smallPageURL = [folder URLByAppendingPathComponent:[NSString stringWithFormat:@"small-%ld.png", (long)page + 1]];
        RunTask(@"/usr/bin/sips", @[@"-Z", @"4000", pageURL.path, @"--out", smallPageURL.path], nil);
        NSImage *pageImage = [[NSImage alloc] initWithContentsOfURL:smallPageURL];
        CGImageRef pageCG = [pageImage CGImageForProposedRect:NULL context:nil hints:nil];
        if (!pageCG) continue;
        CGFloat unitScaleX = 12.0 * originalWidth / CGImageGetWidth(pageCG);
        CGFloat unitScaleY = 12.0 * originalHeight / CGImageGetHeight(pageCG);
        NSArray *items = system[@"items"];
        double left = DBL_MAX, right = 0;
        for (NSDictionary *position in items) {
            left = MIN(left, [position[@"x"] doubleValue]);
            right = MAX(right, [position[@"x"] doubleValue] + [position[@"sx"] doubleValue]);
        }
        double systemY = [system[@"y"] doubleValue], systemHeight = [system[@"sy"] doubleValue];
        double staffTop = systemY + systemHeight * ((double)firstStaff / staffCount);
        double staffBottom = systemY + systemHeight * ((double)endStaff / staffCount);
        CGFloat leftPadding = (firstStaff == 0 && endStaff == staffCount) ? 420 : 60;
        CGFloat x = MAX(0, left / unitScaleX - leftPadding), y = MAX(0, staffTop / unitScaleY - 24);
        CGFloat width = MIN((CGFloat)CGImageGetWidth(pageCG) - x, right / unitScaleX + 22 - x);
        CGFloat height = MIN((CGFloat)CGImageGetHeight(pageCG) - y, (staffBottom - staffTop) / unitScaleY + 48);
        if (width < 10 || height < 10) continue;
        CGImageRef crop = CGImageCreateWithImageInRect(pageCG, CGRectMake(x, y, width, height));
        if (!crop) continue;
        CGFloat shrink = MIN(1.0, 1800.0 / width);
        NSImage *slice = [[NSImage alloc] initWithCGImage:crop size:NSMakeSize(width * shrink, height * shrink)];
        CGImageRelease(crop);
        [slices addObject:slice]; targetWidth = MAX(targetWidth, slice.size.width); targetHeight += slice.size.height;
    }
    if (!slices.count) {
        if (outError) *outError = [NSError errorWithDomain:@"OrchestraNotebook" code:12 userInfo:@{NSLocalizedDescriptionKey:@"谱例裁切失败"}];
        [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
        return nil;
    }
    targetHeight += (slices.count - 1) * 12;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:ceil(targetWidth) pixelsHigh:ceil(targetHeight) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState]; [NSGraphicsContext setCurrentContext:context];
    [[NSColor whiteColor] setFill]; NSRectFill(NSMakeRect(0, 0, targetWidth, targetHeight));
    CGFloat top = targetHeight;
    for (NSImage *slice in slices) {
        top -= slice.size.height;
        [slice drawInRect:NSMakeRect(0, top, slice.size.width, slice.size.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:NO hints:@{NSImageHintInterpolation:@(NSImageInterpolationHigh)}];
        top -= 12;
    }
    [context flushGraphics]; [NSGraphicsContext restoreGraphicsState];
    NSData *result = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    return result;
}

@protocol ScoreDropDelegate <NSObject>
- (void)openScoreURL:(NSURL *)url;
@end

@interface ScoreWebView : WKWebView <NSDraggingDestination>
@property(nonatomic, weak) id<ScoreDropDelegate> scoreDropDelegate;
@end

@implementation ScoreWebView
- (instancetype)initWithFrame:(NSRect)frame configuration:(WKWebViewConfiguration *)configuration {
    if ((self = [super initWithFrame:frame configuration:configuration])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}
- (NSURL *)scoreFromDragging:(id<NSDraggingInfo>)sender {
    NSArray<NSURL *> *urls = [sender.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    for (NSURL *url in urls) if (IsScoreURL(url)) return url;
    return nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return [self scoreFromDragging:sender] ? NSDragOperationCopy : NSDragOperationNone; }
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender { return [self scoreFromDragging:sender] ? NSDragOperationCopy : NSDragOperationNone; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSURL *url = [self scoreFromDragging:sender];
    if (!url) return NO;
    [self.scoreDropDelegate openScoreURL:url];
    return YES;
}
@end

@interface NotePDFExporter : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSWindow *printWindow;
@property(nonatomic, strong) NSURL *destinationURL;
@property(nonatomic, strong) PDFDocument *pdfDocument;
@property(nonatomic) NSInteger pageCount;
@property(nonatomic, copy) void (^completion)(NSError *);
- (void)exportHTML:(NSString *)html toURL:(NSURL *)url completion:(void (^)(NSError *error))completion;
@end

@implementation NotePDFExporter
- (void)exportHTML:(NSString *)html toURL:(NSURL *)url completion:(void (^)(NSError *error))completion {
    self.destinationURL = url;
    self.completion = completion;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 595, 842) configuration:configuration];
    self.webView.navigationDelegate = self;
    self.printWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 595, 842)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.printWindow.releasedWhenClosed = NO;
    self.printWindow.contentView = self.webView;
    [self.printWindow orderOut:nil];
    [self.webView loadHTMLString:html baseURL:nil];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithError:error];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self finishWithError:error];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        NSString *script = @"Math.max(document.documentElement.scrollHeight || 0, document.body.scrollHeight || 0, 842)";
        [self.webView evaluateJavaScript:script completionHandler:^(id value, NSError *error) {
            if (error) {
                [self finishWithError:error];
                return;
            }
            CGFloat contentHeight = MAX(842.0, [value doubleValue]);
            self.pageCount = MAX(1, MIN(200, (NSInteger)ceil(contentHeight / 842.0)));
            self.pdfDocument = [PDFDocument new];
            [self capturePageAtIndex:0];
        }];
    });
}
- (void)capturePageAtIndex:(NSInteger)index {
    if (index >= self.pageCount) {
        BOOL written = [self.pdfDocument writeToURL:self.destinationURL];
        NSError *error = written ? nil : [NSError errorWithDomain:@"OrchestraNotebook.Export" code:2 userInfo:@{NSLocalizedDescriptionKey:@"PDF 文件写入失败。"}];
        [self finishWithError:error];
        return;
    }
    WKPDFConfiguration *configuration = [WKPDFConfiguration new];
    configuration.rect = CGRectMake(0, index * 842.0, 595.0, 842.0);
    [self.webView createPDFWithConfiguration:configuration completionHandler:^(NSData *data, NSError *error) {
        if (error || !data.length) {
            [self finishWithError:error ?: [NSError errorWithDomain:@"OrchestraNotebook.Export" code:3 userInfo:@{NSLocalizedDescriptionKey:@"PDF 页面生成失败。"}]];
            return;
        }
        PDFDocument *pageDocument = [[PDFDocument alloc] initWithData:data];
        if (!pageDocument.pageCount) {
            [self finishWithError:[NSError errorWithDomain:@"OrchestraNotebook.Export" code:4 userInfo:@{NSLocalizedDescriptionKey:@"PDF 页面内容无效。"}]];
            return;
        }
        for (NSInteger pageIndex = 0; pageIndex < pageDocument.pageCount; pageIndex++) {
            PDFPage *page = [pageDocument pageAtIndex:pageIndex];
            if (page) [self.pdfDocument insertPage:page atIndex:self.pdfDocument.pageCount];
        }
        [self capturePageAtIndex:index + 1];
    }];
}
- (void)finishWithError:(NSError *)error {
    void (^completion)(NSError *) = self.completion;
    self.completion = nil;
    [self.printWindow orderOut:nil];
    [self.printWindow close];
    self.printWindow = nil;
    self.webView = nil;
    self.pdfDocument = nil;
    if (completion) completion(error);
}
@end

@interface NotebookController : NSViewController <WKScriptMessageHandler, WKNavigationDelegate, ScoreDropDelegate>
@property(nonatomic, strong) ScoreWebView *webView;
@property(nonatomic, strong) NotePDFExporter *pdfExporter;
@property(nonatomic) BOOL pageReady;
@property(nonatomic, strong) NSTimer *selectionTimer;
@property(nonatomic) NSTimeInterval lastSelectionTimestamp;
- (void)chooseScore:(id)sender;
- (void)relocateScore:(NSDictionary *)request;
- (void)scanScoreFolder:(NSArray *)entries;
- (void)exportNote:(NSDictionary *)payload;
- (void)syncMuseScore:(id)sender;
@end

@implementation NotebookController

- (NSURL *)libraryURL {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [support URLByAppendingPathComponent:@"Orchestra Notebook" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [folder URLByAppendingPathComponent:@"library.json"];
}

- (NSURL *)selectionURL {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/MuseScore4/OrchestraNotebook"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"selection.json"]];
}

- (NSURL *)pluginURL {
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/MuseScore4/Plugins"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    (void)self.selectionURL;
    return [NSURL fileURLWithPath:[folder stringByAppendingPathComponent:@"OrchestraNotebookCapture.qml"]];
}

- (void)loadView {
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1280, 820)];
    self.view = root;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    [configuration.userContentController addScriptMessageHandler:self name:@"bridge"];
    self.webView = [[ScoreWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.scoreDropDelegate = self;
    self.webView.allowsMagnification = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.topAnchor constraintEqualToAnchor:root.topAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor]
    ]];
    NSURL *index = [NSBundle.mainBundle URLForResource:@"index" withExtension:@"html"];
    [self.webView loadFileURL:index allowingReadAccessToURL:index.URLByDeletingLastPathComponent];
}

- (void)dealloc { [self.selectionTimer invalidate]; [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"bridge"]; }

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.pageReady = YES;
    NSData *data = [NSData dataWithContentsOfURL:self.libraryURL];
    NSDictionary *library = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![library isKindOfClass:NSDictionary.class]) library = @{@"version":@1, @"scores":@{}, @"order":@[]};
    [self callJavaScript:@"receiveLibrary" object:library];
    self.selectionTimer = [NSTimer scheduledTimerWithTimeInterval:0.75 target:self selector:@selector(checkMuseScoreSelection:) userInfo:nil repeats:YES];
    [self checkMuseScoreSelection:nil];
}

- (void)callJavaScript:(NSString *)function object:(id)object {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{} options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.%@(%@)", function, json] completionHandler:nil];
}

- (void)showError:(NSString *)title detail:(NSString *)detail {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = detail ?: @"";
    alert.alertStyle = NSAlertStyleWarning;
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}

- (void)chooseScore:(id)sender {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.title = @"选择 MuseScore 乐谱";
    panel.message = @"支持 .mscz 与 .mscx；乐谱只在本机解析。";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK && panel.URL) [self openScoreURL:panel.URL];
    }];
}

- (void)relocateScore:(NSDictionary *)request {
    NSString *scoreId = [request[@"scoreId"] isKindOfClass:NSString.class] ? request[@"scoreId"] : nil;
    NSString *oldPath = [request[@"oldPath"] isKindOfClass:NSString.class] ? request[@"oldPath"] : @"";
    NSString *scoreTitle = [request[@"scoreTitle"] isKindOfClass:NSString.class] ? request[@"scoreTitle"] : @"这部乐谱";
    if (!scoreId.length) return;
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.title = @"重新定位 MuseScore 乐谱";
    panel.message = @"请选择这部乐谱移动或改名后的 .mscz / .mscx 文件。全部旧笔记链接会一起更新。";
    panel.prompt = @"重新定位";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSURL *url = panel.URL;
        if (!IsScoreURL(url)) {
            [self showError:@"暂不支持这个文件" detail:@"请选择 MuseScore 的 .mscz 或 .mscx 文件。"];
            return;
        }
        [self callJavaScript:@"setBusy" object:@{@"busy":@YES, @"message":@"正在验证并重新定位乐谱…"}];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *error = nil;
            NSDictionary *score = ParseScoreURL(url, &error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self callJavaScript:@"setBusy" object:@{@"busy":@NO}];
                if (!score) {
                    [self showError:@"无法读取新位置的乐谱" detail:error.localizedDescription ?: @"乐谱格式可能已损坏或暂不兼容。"];
                    return;
                }
                NSAlert *confirm = [NSAlert new];
                confirm.messageText = [NSString stringWithFormat:@"确认重新定位“%@”？", scoreTitle];
                confirm.informativeText = [NSString stringWithFormat:@"旧位置：\n%@\n\n新位置：\n%@\n\n确认后，这个分区及全部旧笔记的位置链接都会更新；笔记、谱例和小节范围保持不变。", oldPath.length ? oldPath : @"（未知）", url.path];
                [confirm addButtonWithTitle:@"更新位置"];
                [confirm addButtonWithTitle:@"取消"];
                [confirm beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse answer) {
                    if (answer == NSAlertFirstButtonReturn) [self callJavaScript:@"receiveRelocatedScore" object:@{@"scoreId":scoreId, @"score":score}];
                }];
            });
        });
    }];
}

- (void)scanScoreFolder:(NSArray *)entries {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.allowsMultipleSelection = NO;
    panel.title = @"扫描乐谱文件夹";
    panel.message = @"将递归扫描文件夹；仅自动修复旧路径已失效且文件名唯一匹配的乐谱。";
    panel.prompt = @"开始扫描";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSURL *root = panel.URL;
        NSArray *safeEntries = [entries isKindOfClass:NSArray.class] ? [entries copy] : @[];
        [self callJavaScript:@"setBusy" object:@{@"busy":@YES, @"message":@"正在扫描乐谱文件夹…"}];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSFileManager *manager = NSFileManager.defaultManager;
            NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *pathsByName = [NSMutableDictionary dictionary];
            NSDirectoryEnumerator<NSURL *> *enumerator = [manager enumeratorAtURL:root
                                                        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                           options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                      errorHandler:^BOOL(NSURL *url, NSError *error) { return YES; }];
            NSUInteger scanned = 0;
            for (NSURL *url in enumerator) {
                NSNumber *regular = nil;
                [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
                if (!regular.boolValue || !IsScoreURL(url)) continue;
                NSString *key = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
                if (!pathsByName[key]) pathsByName[key] = [NSMutableArray array];
                [pathsByName[key] addObject:url.path];
                scanned += 1;
            }
            NSMutableArray *matches = [NSMutableArray array];
            NSUInteger missing = 0, ambiguous = 0, unmatched = 0;
            for (id value in safeEntries) {
                if (![value isKindOfClass:NSDictionary.class]) continue;
                NSDictionary *entry = value;
                NSString *scoreId = [entry[@"scoreId"] isKindOfClass:NSString.class] ? entry[@"scoreId"] : nil;
                NSString *oldPath = [entry[@"path"] isKindOfClass:NSString.class] ? entry[@"path"] : nil;
                if (!scoreId.length || !oldPath.length || [manager fileExistsAtPath:oldPath]) continue;
                missing += 1;
                NSString *key = oldPath.lastPathComponent.precomposedStringWithCanonicalMapping.lowercaseString;
                NSArray<NSString *> *candidates = pathsByName[key] ?: @[];
                if (candidates.count == 1) [matches addObject:@{@"scoreId":scoreId, @"oldPath":oldPath, @"newPath":candidates.firstObject}];
                else if (candidates.count > 1) ambiguous += 1;
                else unmatched += 1;
            }
            NSDictionary *result = @{@"matches":matches, @"missing":@(missing), @"ambiguous":@(ambiguous), @"unmatched":@(unmatched), @"scanned":@(scanned), @"root":root.path ?: @""};
            dispatch_async(dispatch_get_main_queue(), ^{
                [self callJavaScript:@"setBusy" object:@{@"busy":@NO}];
                [self callJavaScript:@"receiveScoreScanResults" object:result];
            });
        });
    }];
}

- (void)openScoreURL:(NSURL *)url {
    if (!IsScoreURL(url)) {
        [self showError:@"暂不支持这个文件" detail:@"请选择 MuseScore 的 .mscz 或 .mscx 文件。"];
        return;
    }
    [self callJavaScript:@"setBusy" object:@{@"busy":@YES, @"message":@"正在解析乐器与小节…"}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSDictionary *score = ParseScoreURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self callJavaScript:@"setBusy" object:@{@"busy":@NO}];
            if (score) [self callJavaScript:@"receiveScore" object:score];
            else [self showError:@"无法读取乐谱" detail:error.localizedDescription ?: @"乐谱格式可能已损坏或暂不兼容。"];
        });
    });
}

- (void)syncMuseScore:(id)sender {
    NSArray *paths = MuseScoreSessionPaths();
    NSString *path = [paths isKindOfClass:NSArray.class] ? paths.lastObject : nil;
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [self showError:@"没有找到当前乐谱" detail:@"请先在 MuseScore Studio 中打开并保存乐谱，或直接把乐谱拖到配器手记。"];
        return;
    }
    [self openScoreURL:[NSURL fileURLWithPath:path]];
}

- (BOOL)installPluginShowingHelp:(BOOL)showHelp {
    NSURL *source = [NSBundle.mainBundle URLForResource:@"OrchestraNotebookCapture" withExtension:@"qml"];
    NSURL *destination = self.pluginURL;
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:destination error:nil];
    BOOL installed = source && [NSFileManager.defaultManager copyItemAtURL:source toURL:destination error:&error];
    if (!installed) {
        [self showError:@"无法安装 MuseScore 连接" detail:error.localizedDescription ?: @"没有找到内置插件文件。"];
        return NO;
    }
    if (showHelp) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"MuseScore 连接已安装";
        alert.informativeText = @"请先完整退出 MuseScore Studio（⌘Q，关闭所有窗口）再重新打开，然后在插件管理器启用「配器手记：从选区新建笔记」。先从“插件”菜单运行一次确认；之后建议在快捷键设置中分配 Control+Option+N（⌃⌥N），避免与 MuseScore 的“新建乐谱”快捷键冲突。";
        [alert addButtonWithTitle:@"知道了"];
        [alert addButtonWithTitle:@"显示插件文件"];
        [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertSecondButtonReturn) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[destination]];
        }];
    }
    return YES;
}

- (void)captureSelection {
    NSURL *source = [NSBundle.mainBundle URLForResource:@"OrchestraNotebookCapture" withExtension:@"qml"];
    NSData *bundled = [NSData dataWithContentsOfURL:source];
    NSData *installed = [NSData dataWithContentsOfURL:self.pluginURL];
    if (!bundled.length || ![bundled isEqualToData:installed]) {
        if ([self installPluginShowingHelp:YES]) return;
    }
    NSURL *applicationURL = [NSURL fileURLWithPath:@"/Applications/MuseScore 4.app"];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:applicationURL configuration:configuration completionHandler:nil];
    [self callJavaScript:@"showToast" object:@{@"message":@"请在 MuseScore 选择区间，再运行“配器手记：从选区新建笔记”"}];
}

- (void)checkMuseScoreSelection:(NSTimer *)timer {
    NSData *data = [NSData dataWithContentsOfURL:self.selectionURL];
    NSDictionary *selection = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![selection isKindOfClass:NSDictionary.class]) return;
    NSTimeInterval timestamp = [selection[@"timestamp"] doubleValue];
    if (timestamp <= self.lastSelectionTimestamp) return;
    self.lastSelectionTimestamp = timestamp;
    if ([[NSDate date] timeIntervalSince1970] * 1000.0 - timestamp > 30000.0) return;
    NSMutableDictionary *resolvedSelection = [selection mutableCopy];
    NSString *scorePath = ResolveMuseScorePath(selection);
    if (scorePath.length) resolvedSelection[@"scorePath"] = scorePath;
    if (!scorePath.length || ![NSFileManager.defaultManager fileExistsAtPath:scorePath]) {
        [self showError:@"无法接收选区" detail:@"请先保存当前 MuseScore 乐谱，再重新运行插件。"];
        return;
    }
    [self callJavaScript:@"setBusy" object:@{@"busy":@YES, @"message":@"正在读取选区位置…"}];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *parseError = nil;
        NSDictionary *score = ParseScoreURL([NSURL fileURLWithPath:scorePath], &parseError);
        NSMutableDictionary *payload = [resolvedSelection mutableCopy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self callJavaScript:@"setBusy" object:@{@"busy":@NO}];
            if (score) {
                [self callJavaScript:@"receiveScore" object:score];
                [self callJavaScript:@"receiveMuseScoreSelection" object:payload];
                [NSApp activateIgnoringOtherApps:YES]; [self.view.window makeKeyAndOrderFront:nil];
            } else [self showError:@"无法读取所选乐谱" detail:parseError.localizedDescription ?: @"请先保存乐谱。"];
        });
    });
}

- (void)pasteImageFromClipboard {
    NSImage *image = [NSPasteboard.generalPasteboard readObjectsForClasses:@[NSImage.class] options:@{}].firstObject;
    NSData *tiff = image.TIFFRepresentation;
    NSBitmapImageRep *rep = tiff ? [NSBitmapImageRep imageRepWithData:tiff] : nil;
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSDictionary *payload = png.length ? @{@"dataURL":[NSString stringWithFormat:@"data:image/png;base64,%@", [png base64EncodedStringWithOptions:0]]} : @{};
    [self callJavaScript:@"receiveClipboardImage" object:payload];
}

- (void)chooseNoteImage {
    NSOpenPanel *panel = NSOpenPanel.openPanel;
    panel.canChooseDirectories = NO;
    panel.canChooseFiles = YES;
    panel.allowsMultipleSelection = NO;
    panel.title = @"选择要插入笔记的图片";
    panel.message = @"图片会保存在本机笔记资料库中（最大 8 MB）。";
    panel.allowedContentTypes = @[UTTypeImage];
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfURL:panel.URL options:NSDataReadingMappedIfSafe error:&readError];
        if (!data.length || readError) {
            [self callJavaScript:@"receiveUploadedImage" object:@{@"error": readError.localizedDescription ?: @"无法读取这张图片"}];
            return;
        }
        if (data.length > 8 * 1024 * 1024) {
            [self callJavaScript:@"receiveUploadedImage" object:@{@"error": @"图片请控制在 8 MB 以内"}];
            return;
        }
        UTType *fileType = [UTType typeWithFilenameExtension:panel.URL.pathExtension];
        NSString *mime = fileType.preferredMIMEType ?: @"application/octet-stream";
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, [data base64EncodedStringWithOptions:0]];
        [self callJavaScript:@"receiveUploadedImage" object:@{@"dataURL":dataURL, @"name":panel.URL.lastPathComponent ?: @"上传的图片"}];
    }];
}

- (void)saveLibraryObject:(id)object {
    if (![NSJSONSerialization isValidJSONObject:object]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:self.libraryURL options:NSDataWritingAtomic error:nil];
}

- (void)exportNote:(NSDictionary *)payload {
    if (![payload isKindOfClass:NSDictionary.class]) return;
    NSString *format = [payload[@"format"] isKindOfClass:NSString.class] ? [payload[@"format"] lowercaseString] : @"";
    if (![@[@"md", @"pdf"] containsObject:format]) return;
    NSString *title = [payload[@"title"] isKindOfClass:NSString.class] ? payload[@"title"] : @"无标题";
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/:\\\n\r"];
    NSString *safeTitle = [[title componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@"-"];
    if (!safeTitle.length) safeTitle = @"无标题";
    NSSavePanel *panel = NSSavePanel.savePanel;
    panel.title = [format isEqualToString:@"pdf"] ? @"导出笔记为 PDF" : @"导出笔记为 Markdown";
    panel.nameFieldStringValue = [safeTitle stringByAppendingPathExtension:format];
    UTType *type = [UTType typeWithFilenameExtension:format];
    if (type) panel.allowedContentTypes = @[type];
    panel.canCreateDirectories = YES;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        if ([format isEqualToString:@"md"]) {
            NSString *markdown = [payload[@"markdown"] isKindOfClass:NSString.class] ? payload[@"markdown"] : @"";
            NSError *error = nil;
            BOOL written = [markdown writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
            if (!written) [self showError:@"无法导出 Markdown" detail:error.localizedDescription ?: @"写入文件失败。"];
            else [self callJavaScript:@"showToast" object:@{@"message":@"Markdown 已导出"}];
            return;
        }
        if (self.pdfExporter) {
            [self showError:@"正在导出 PDF" detail:@"请等待当前导出完成后再试。"];
            return;
        }
        NSString *html = [payload[@"html"] isKindOfClass:NSString.class] ? payload[@"html"] : @"";
        self.pdfExporter = [NotePDFExporter new];
        __weak typeof(self) weakSelf = self;
        [self.pdfExporter exportHTML:html toURL:panel.URL completion:^(NSError *error) {
            NotebookController *strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) [strongSelf showError:@"无法导出 PDF" detail:error.localizedDescription ?: @"生成 PDF 失败。"];
            else [strongSelf callJavaScript:@"showToast" object:@{@"message":@"PDF 已导出"}];
            strongSelf.pdfExporter = nil;
        }];
    }];
}

- (void)openRoute:(NSDictionary *)route {
    NSString *path = route[@"path"];
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [self showError:@"找不到原乐谱" detail:@"文件可能被移动或重命名。重新打开一次即可更新路径。"];
        return;
    }
    NSURL *museScore = [NSURL fileURLWithPath:@"/Applications/MuseScore 4.app"];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    NSNumber *measure = route[@"measure"];
    NSNumber *page = route[@"page"];
    NSString *query = measure.integerValue > 0 ? measure.stringValue : (page.integerValue > 0 ? [NSString stringWithFormat:@"p%@", page] : nil);
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};
    BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
    [NSWorkspace.sharedWorkspace openURLs:@[[NSURL fileURLWithPath:path]] withApplicationAtURL:museScore configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [self showError:@"无法打开 MuseScore" detail:error.localizedDescription];
                return;
            }
            if (!query.length) return;
            if (!trusted) {
                [NSPasteboard.generalPasteboard clearContents];
                [NSPasteboard.generalPasteboard setString:query forType:NSPasteboardTypeString];
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"需要重新授权新版配器手记";
                alert.informativeText = @"以前的 ad-hoc 签名会在每次更新后改变，导致已勾选的辅助功能失效。本版已改为稳定签名要求。请在“隐私与安全性 → 辅助功能”中移除旧的配器手记，再加入并启用当前 App；通常只需做这一次。小节号已复制。";
                [alert addButtonWithTitle:@"打开辅助功能设置"];
                [alert addButtonWithTitle:@"仅打开乐谱"];
                [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
                    if (response == NSAlertFirstButtonReturn) {
                        NSURL *settingsURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
                        [NSWorkspace.sharedWorkspace openURL:settingsURL];
                    }
                }];
                return;
            }
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            pid_t targetPID = app.processIdentifier;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1800 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CGEventRef keyDown = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)3, true);
                CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
                CGEventPostToPid(targetPID, keyDown);
                CFRelease(keyDown);
                CGEventRef keyUp = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)3, false);
                CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
                CGEventPostToPid(targetPID, keyUp);
                CFRelease(keyUp);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 320 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                    UniChar chars[32];
                    NSUInteger length = MIN((NSUInteger)31, query.length);
                    [query getCharacters:chars range:NSMakeRange(0, length)];
                    CGEventRef textEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
                    CGEventKeyboardSetUnicodeString(textEvent, length, chars);
                    CGEventPostToPid(targetPID, textEvent);
                    CFRelease(textEvent);
                    CGEventRef enterDown = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)36, true);
                    CGEventPostToPid(targetPID, enterDown);
                    CFRelease(enterDown);
                    CGEventRef enterUp = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)36, false);
                    CGEventPostToPid(targetPID, enterUp);
                    CFRelease(enterUp);
                    [self callJavaScript:@"showToast" object:@{@"message":[NSString stringWithFormat:@"已跳转到 m.%@", query]}];
                });
            });
        });
    }];
}

- (void)copyPNGDataURL:(NSString *)dataURL {
    NSRange comma = [dataURL rangeOfString:@","];
    if (comma.location == NSNotFound) return;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:[dataURL substringFromIndex:comma.location + 1] options:0];
    NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
    if (!image) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard writeObjects:@[image]];
    [self callJavaScript:@"showToast" object:@{@"message":@"可视化已复制到剪贴板"}];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : @{};
    NSString *type = body[@"type"];
    if ([type isEqualToString:@"chooseScore"]) [self chooseScore:nil];
    else if ([type isEqualToString:@"relocateScore"]) [self relocateScore:body];
    else if ([type isEqualToString:@"scanScoreFolder"]) [self scanScoreFolder:body[@"entries"]];
    else if ([type isEqualToString:@"syncMuseScore"]) [self syncMuseScore:nil];
    else if ([type isEqualToString:@"captureSelection"]) [self captureSelection];
    else if ([type isEqualToString:@"installPlugin"]) [self installPluginShowingHelp:YES];
    else if ([type isEqualToString:@"pasteImage"]) [self pasteImageFromClipboard];
    else if ([type isEqualToString:@"chooseNoteImage"]) [self chooseNoteImage];
    else if ([type isEqualToString:@"exportNote"]) [self exportNote:body[@"payload"]];
    else if ([type isEqualToString:@"saveLibrary"]) [self saveLibraryObject:body[@"payload"]];
    else if ([type isEqualToString:@"openRoute"]) [self openRoute:body[@"payload"] ?: @{}];
    else if ([type isEqualToString:@"revealFile"]) {
        NSString *path = body[@"path"];
        if (path.length) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
    } else if ([type isEqualToString:@"copyPNG"]) [self copyPNGDataURL:body[@"data"]];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NotebookController *controller;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [self buildMainMenu];
    self.controller = [NotebookController new];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1320, 840)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"配器手记";
    self.window.titleVisibility = NSWindowTitleVisible;
    self.window.titlebarAppearsTransparent = NO;
    self.window.movableByWindowBackground = YES;
    self.window.minSize = NSMakeSize(980, 640);
    self.window.contentViewController = self.controller;
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    if (arguments.count > 1) {
        NSURL *url = [NSURL fileURLWithPath:arguments[1]];
        if (IsScoreURL(url)) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self.controller openScoreURL:url]; });
    }
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) if (IsScoreURL(url)) { [self.controller openScoreURL:url]; [self.window makeKeyAndOrderFront:nil]; break; }
}
- (void)buildMainMenu {
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new]; [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"关于配器手记" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出配器手记" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    appItem.submenu = appMenu;
    NSMenuItem *fileItem = [NSMenuItem new]; [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"打开乐谱…" action:@selector(chooseScore:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"同步 MuseScore 当前乐谱" action:@selector(syncMuseScore:) keyEquivalent:@"r"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"关闭窗口" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;
    NSMenuItem *editItem = [NSMenuItem new]; [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"拷贝" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    NSApp.mainMenu = mainMenu;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 9 && strcmp(argv[1], "--render-snippet") == 0) {
            NSDictionary *selection = @{
                @"scorePath":[NSString stringWithUTF8String:argv[2]],
                @"startMeasure":@([[NSString stringWithUTF8String:argv[3]] integerValue]),
                @"endMeasure":@([[NSString stringWithUTF8String:argv[4]] integerValue]),
                @"startStaff":@([[NSString stringWithUTF8String:argv[5]] integerValue]),
                @"endStaff":@([[NSString stringWithUTF8String:argv[6]] integerValue]),
                @"staffCount":@([[NSString stringWithUTF8String:argv[7]] integerValue])
            };
            NSError *error = nil;
            NSData *png = PNGDataForSelection(selection, &error);
            if (!png || ![png writeToFile:[NSString stringWithUTF8String:argv[8]] options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "%s\n", (error.localizedDescription ?: @"render failed").UTF8String); return 1;
            }
            return 0;
        }
        if (argc >= 3 && strcmp(argv[1], "--inspect") == 0) {
            NSError *error = nil;
            NSDictionary *result = ParseScoreURL([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]], &error);
            if (!result) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        application.activationPolicy = NSApplicationActivationPolicyRegular;
        [application run];
    }
    return 0;
}
