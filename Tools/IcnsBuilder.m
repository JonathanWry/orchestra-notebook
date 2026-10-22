#import <Foundation/Foundation.h>

static void appendChunk(NSMutableData *result, NSString *type, NSString *path) {
    NSData *png = [NSData dataWithContentsOfFile:path];
    if (!png) return;
    [result appendData:[type dataUsingEncoding:NSASCIIStringEncoding]];
    uint32_t chunkSize = CFSwapInt32HostToBig((uint32_t)png.length + 8);
    [result appendBytes:&chunkSize length:sizeof(chunkSize)];
    [result appendData:png];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 9) return 2;
        NSMutableData *body = [NSMutableData data];
        NSArray<NSString *> *types = @[@"icp4", @"icp5", @"icp6", @"ic07", @"ic08", @"ic09", @"ic10"];
        for (NSInteger index = 0; index < types.count; index++) {
            appendChunk(body, types[index], [NSString stringWithUTF8String:argv[index + 2]]);
        }
        NSMutableData *result = [NSMutableData data];
        [result appendData:[@"icns" dataUsingEncoding:NSASCIIStringEncoding]];
        uint32_t totalSize = CFSwapInt32HostToBig((uint32_t)body.length + 8);
        [result appendBytes:&totalSize length:sizeof(totalSize)];
        [result appendData:body];
        return [result writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES] ? 0 : 1;
    }
}
