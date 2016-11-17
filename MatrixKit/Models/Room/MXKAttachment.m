/*
 Copyright 2015 OpenMarket Ltd
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXKAttachment.h"

#import "MXKMediaManager.h"
#import "MXKTools.h"
#import "MXEncryptedAttachments.h"

// The size of thumbnail we request from the server
// Note that this is smaller than the ones we upload: when sending, one size
// must fit all, including the web which will want relatively high res thumbnails.
// We, however, are a mobile client and so would prefer smaller thumbnails, which
// we can have if they're being generated by the media repo.
static const int kThumbnailWidth = 320;
static const int kThumbnailHeight = 240;

const NSString *kMXKAttachmentErrorDomain = @"kMXKAttachmentErrorDomain";

@interface MXKAttachment ()
{
    /**
     Observe Attachment download
     */
    id onAttachmentDownloadEndObs;
    id onAttachmentDownloadFailureObs;
    
    /**
     The local path used to store the attachment with its original name
     */
    NSString* documentCopyPath;
}

@end

@interface MXKAttachment ()
@property (nonatomic) MXSession *sess;
@end

@implementation MXKAttachment

- (instancetype)initWithEvent:(MXEvent *)mxEvent andMatrixSession:(MXSession*)mxSession
{
    self = [super init];
    self.sess = mxSession;
    if (self) {
        // Make a copy as the data can be read at anytime later
        _event = mxEvent;
        
        // Set default thumbnail orientation
        _thumbnailOrientation = UIImageOrientationUp;
        
        NSString *msgtype =  _event.content[@"msgtype"];
        if ([msgtype isEqualToString:kMXMessageTypeImage])
        {
            _type = MXKAttachmentTypeImage;
        }
        else if ([msgtype isEqualToString:kMXMessageTypeAudio])
        {
            // Not supported yet
            //_type = MXKAttachmentTypeAudio;
            return nil;
        }
        else if ([msgtype isEqualToString:kMXMessageTypeVideo])
        {
            _type = MXKAttachmentTypeVideo;
        }
        else if ([msgtype isEqualToString:kMXMessageTypeLocation])
        {
            // Not supported yet
            // _type = MXKAttachmentTypeLocation;
            return nil;
        }
        else if ([msgtype isEqualToString:kMXMessageTypeFile])
        {
            _type = MXKAttachmentTypeFile;
        }
        else
        {
            return nil;
        }
        
        _originalFileName = [_event.content[@"body"] isKindOfClass:[NSString class]] ? _event.content[@"body"] : nil;
        // Retrieve content url/info
        if (mxEvent.content[@"file"][@"url"])
        {
            _contentURL = mxEvent.content[@"file"][@"url"];
        }
        else
        {
            _contentURL = mxEvent.content[@"url"];
        }
        
        // Check provided url (it may be a matrix content uri, we use SDK to build absoluteURL)
        _actualURL = [mxSession.matrixRestClient urlOfContent:_contentURL];
        
        NSString *mimetype = nil;
        if (mxEvent.content[@"info"])
        {
            mimetype = mxEvent.content[@"info"][@"mimetype"];
        }
        
        _cacheFilePath = [MXKMediaManager cachePathForMediaWithURL:_actualURL andType:mimetype inFolder:mxEvent.roomId];
        _contentInfo = mxEvent.content[@"info"];
    }
    return self;
}

- (void)dealloc
{
    [self destroy];
}

- (void)destroy
{
    if (onAttachmentDownloadEndObs)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadEndObs];
        onAttachmentDownloadEndObs = nil;
    }

    if (onAttachmentDownloadFailureObs)
    {
        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadFailureObs];
        onAttachmentDownloadFailureObs = nil;
    }
    
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
}

- (BOOL)isEncrypted
{
    if (self.event.content[@"file"][@"url"]) return YES;
    return NO;
}

- (NSString *)thumbnailURL
{
    return [self getThumbnailUrlForSize:CGSizeMake(kThumbnailWidth, kThumbnailHeight)];
}

- (NSString *)getThumbnailUrlForSize:(CGSize)size
{
    NSDictionary *thumbnail_file = self.event.content[@"info"][@"thumbnail_file"];
    if (thumbnail_file && thumbnail_file[@"url"]) {
        // there's an encrypted thumbnail: we just return the mxc url
        // since it will have to be decrypted before downloading anyway,
        // so the URL is really just a key into the cache.
        return thumbnail_file[@"url"];
    }
    
    NSString *msgtype =  self.event.content[@"msgtype"];
    if ([msgtype isEqualToString:kMXMessageTypeVideo])
    {
        _contentInfo = self.event.content[@"info"];
        
        if (_contentInfo)
        {
            // Unencrypted video thumbnail
            NSString *unencrypted_video_thumb_url = _contentInfo[@"thumbnail_url"];
            unencrypted_video_thumb_url = [self.sess.matrixRestClient urlOfContent:unencrypted_video_thumb_url];
            
            return unencrypted_video_thumb_url;
        }
    }
    
    NSString *unencrypted_url = self.event.content[@"url"];
    if (unencrypted_url)
    {
        return [self.sess.matrixRestClient urlOfContentThumbnail:unencrypted_url
                                                   toFitViewSize:size
                                                      withMethod:MXThumbnailingMethodScale];
    }
    
    return nil;
}

- (NSString *)thumbnailMimeType
{
    NSDictionary *thumbnail_file = self.event.content[@"thumbnail_file"];
    if (thumbnail_file && thumbnail_file[@"mimetype"])
    {
        return thumbnail_file[@"mimetype"];
    }
    return nil;
}

- (UIImage *)getCachedThumbnail {
    NSString *cacheFilePath = [MXKMediaManager cachePathForMediaWithURL:self.thumbnailURL
                                                                andType:self.thumbnailMimeType
                                                               inFolder:self.event.roomId];
    
    UIImage *thumb = [MXKMediaManager getFromMemoryCacheWithFilePath:cacheFilePath];
    if (thumb) return thumb;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:cacheFilePath]) {
        return [MXKMediaManager loadThroughCacheWithFilePath:cacheFilePath];
    }
    return nil;
}

- (void)getThumbnail:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure {
    if (!self.thumbnailURL) {
        // there is no thumbnail: if we're an image, return the full size image. Otherwise, nothing we can do.
        if (_type == MXKAttachmentTypeImage) {
            [self getImage:onSuccess failure:onFailure];
        }
        return;
    }
    
    NSString *thumbCachePath = [MXKMediaManager cachePathForMediaWithURL:self.thumbnailURL
                                                                andType:self.thumbnailMimeType
                                                               inFolder:self.event.roomId];
    UIImage *thumb = [MXKMediaManager getFromMemoryCacheWithFilePath:thumbCachePath];
    if (thumb)
    {
        onSuccess(thumb);
        return;
    }
    
    NSDictionary *thumbnail_file = self.event.content[@"info"][@"thumbnail_file"];
    if (thumbnail_file && thumbnail_file[@"url"])
    {
        void (^decryptAndCache)() = ^{
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:thumbCachePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:thumbnail_file inputStream:instream outputStream:outstream];
            if (err) {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                if (onFailure) onFailure(err);
                return;
            }
            
            UIImage *img = [UIImage imageWithData:[outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]];
            [MXKMediaManager cacheImage:img withCachePath:thumbCachePath];
            onSuccess(img);
        };
        
        if ([[NSFileManager defaultManager] fileExistsAtPath:thumbCachePath])
        {
            decryptAndCache();
        }
        else
        {
            NSString *actualUrl = [self.sess.matrixRestClient urlOfContent:thumbnail_file[@"url"]];
            [MXKMediaManager downloadMediaFromURL:actualUrl andSaveAtFilePath:thumbCachePath success:^() {
                decryptAndCache();
            } failure:^(NSError *error)
            {
                if (onFailure) onFailure(error);
            }];
        }
    }
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:thumbCachePath])
    {
        onSuccess([MXKMediaManager loadThroughCacheWithFilePath:thumbCachePath]);
    } else {
        [MXKMediaManager downloadMediaFromURL:self.thumbnailURL andSaveAtFilePath:thumbCachePath success:^{
            onSuccess([MXKMediaManager loadThroughCacheWithFilePath:thumbCachePath]);
        } failure:^(NSError *error) {
            if (onFailure) onFailure(error);
        }];
    }
}

- (void)getImage:(void (^)(UIImage *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self getAttachmentData:^(NSData *data) {
        UIImage *img = [UIImage imageWithData:data];
        if (onSuccess) onSuccess(img);
    } failure:^(NSError *error) {
        if (onFailure) onFailure(error);
    }];
}

- (void)getAttachmentData:(void (^)(NSData *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self prepare:^{
        NSDictionary *file_info = self.event.content[@"file"];
        if (file_info) {
            // decrypt the encrypted file
            NSInputStream *instream = [[NSInputStream alloc] initWithFileAtPath:_cacheFilePath];
            NSOutputStream *outstream = [[NSOutputStream alloc] initToMemory];
            NSError *err = [MXEncryptedAttachments decryptAttachment:file_info inputStream:instream outputStream:outstream];
            if (err) {
                NSLog(@"Error decrypting attachment! %@", err.userInfo);
                return;
            }
            onSuccess([outstream propertyForKey:NSStreamDataWrittenToMemoryStreamKey]);
        } else {
            onSuccess([NSData dataWithContentsOfFile:_cacheFilePath]);
        }
    } failure:^(NSError *error) {
        if (onFailure) onFailure(error);
    }];
}

- (void)decryptToTempFile:(void (^)(NSString *))onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self prepare:^{
        NSString *tempPath = [self getTempFile];
        if (!tempPath)
        {
            if (onFailure) onFailure([NSError errorWithDomain:kMXKAttachmentErrorDomain code:0 userInfo:@{@"err": @"error_creating_temp_file"}]);
            return;
        }
        
        NSInputStream *inStream = [NSInputStream inputStreamWithFileAtPath:_cacheFilePath];
        NSOutputStream *outStream = [NSOutputStream outputStreamToFileAtPath:tempPath append:NO];
        
        NSError *err = [MXEncryptedAttachments decryptAttachment:self.event.content[@"file"] inputStream:inStream outputStream:outStream];
        if (err) {
            if (onFailure) onFailure(err);
            return;
        }
        onSuccess(tempPath);
    } failure:^(NSError *error) {
        if (onFailure) onFailure(error);
    }];
}

- (NSString *)getTempFile
{
    NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"attatchment.XXXXXX"];
    const char *templateCstr = [template fileSystemRepresentation];
    char *tempPathCstr = (char *)malloc(strlen(templateCstr) + 1);
    strcpy(tempPathCstr, templateCstr);
    
    char *result = mktemp(tempPathCstr);
    if (!result)
    {
        return nil;
    }
    
    NSString *tempPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:tempPathCstr
                                                                                     length:strlen(result)];
    free(tempPathCstr);
    return tempPath;
}

- (void)prepare:(void (^)())onAttachmentReady failure:(void (^)(NSError *error))onFailure
{
    if ([[NSFileManager defaultManager] fileExistsAtPath:_cacheFilePath])
    {
        // Done
        if (onAttachmentReady)
        {
            onAttachmentReady ();
        }
    }
    else
    {
        // Trigger download if it is not already in progress
        MXKMediaLoader* loader = [MXKMediaManager existingDownloaderWithOutputFilePath:_cacheFilePath];
        if (!loader)
        {
            loader = [MXKMediaManager downloadMediaFromURL:_actualURL andSaveAtFilePath:_cacheFilePath];
        }
        
        if (loader)
        {
            // Add observers
            onAttachmentDownloadEndObs = [[NSNotificationCenter defaultCenter] addObserverForName:kMXKMediaDownloadDidFinishNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                
                // Sanity check
                if ([notif.object isKindOfClass:[NSString class]])
                {
                    NSString* url = notif.object;
                    NSString* cacheFilePath = notif.userInfo[kMXKMediaLoaderFilePathKey];
                    
                    if ([url isEqualToString:_actualURL] && cacheFilePath.length)
                    {
                        // Remove the observers
                        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadEndObs];
                        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadFailureObs];
                        onAttachmentDownloadEndObs = nil;
                        onAttachmentDownloadFailureObs = nil;
                        
                        if (onAttachmentReady)
                        {
                            onAttachmentReady ();
                        }
                    }
                }
            }];
            
            onAttachmentDownloadFailureObs = [[NSNotificationCenter defaultCenter] addObserverForName:kMXKMediaDownloadDidFailNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notif) {
                
                // Sanity check
                if ([notif.object isKindOfClass:[NSString class]])
                {
                    NSString* url = notif.object;
                    NSError* error = notif.userInfo[kMXKMediaLoaderErrorKey];
                    
                    if ([url isEqualToString:_actualURL])
                    {
                        // Remove the observers
                        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadEndObs];
                        [[NSNotificationCenter defaultCenter] removeObserver:onAttachmentDownloadFailureObs];
                        onAttachmentDownloadEndObs = nil;
                        onAttachmentDownloadFailureObs = nil;
                        
                        if (onFailure)
                        {
                            onFailure (error);
                        }
                    }
                }
            }];
        }
        else if (onFailure)
        {
            onFailure (nil);
        }
    }
}

- (void)save:(void (^)())onSuccess failure:(void (^)(NSError *error))onFailure
{
    if (_type == MXKAttachmentTypeImage || _type == MXKAttachmentTypeVideo)
    {
        [self prepare:^{
            
            NSURL* url = [NSURL fileURLWithPath:_cacheFilePath];
            
            [MXKMediaManager saveMediaToPhotosLibrary:url
                                              isImage:(_type == MXKAttachmentTypeImage)
                                              success:^(NSURL *assetURL){
                                                  if (onSuccess)
                                                  {
                                                      onSuccess();
                                                  }
                                              }
                                              failure:onFailure];
        } failure:onFailure];
    }
    else
    {
        // Not supported
        if (onFailure)
        {
            onFailure(nil);
        }
    }
}

- (void)copy:(void (^)())onSuccess failure:(void (^)(NSError *error))onFailure
{
    [self prepare:^{
        
        if (_type == MXKAttachmentTypeImage)
        {
            [[UIPasteboard generalPasteboard] setImage:[UIImage imageWithContentsOfFile:_cacheFilePath]];
            if (onSuccess)
            {
                onSuccess();
            }
        }
        else
        {
            NSData* data = [NSData dataWithContentsOfFile:_cacheFilePath options:(NSDataReadingMappedAlways | NSDataReadingUncached) error:nil];
            
            if (data)
            {
                NSString* UTI = (__bridge_transfer NSString *) UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[_cacheFilePath pathExtension] , NULL);
                
                if (UTI)
                {
                    [[UIPasteboard generalPasteboard] setData:data forPasteboardType:UTI];
                    if (onSuccess)
                    {
                        onSuccess();
                    }
                }
            }
        }
        
        // Unexpected error
        if (onFailure)
        {
            onFailure(nil);
        }
        
    } failure:onFailure];
}

- (void)prepareShare:(void (^)(NSURL *fileURL))onReadyToShare failure:(void (^)(NSError *error))onFailure
{
    // First download data if it is not already done
    [self prepare:^{
        
        // Prepare the file URL by considering the original file name (if any)
        NSURL *fileUrl;
        
        // Check whether the original name retrieved from event body has extension
        if (_originalFileName && [_originalFileName pathExtension].length)
        {
            // Copy the cached file to restore its original name
            // Note:  We used previously symbolic link (instead of copy) but UIDocumentInteractionController failed to open Office documents (.docx, .pptx...).
            documentCopyPath = [[MXKMediaManager getCachePath] stringByAppendingPathComponent:_originalFileName];
            
            [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
            if ([[NSFileManager defaultManager] copyItemAtPath:_cacheFilePath toPath:documentCopyPath error:nil])
            {
                fileUrl = [NSURL fileURLWithPath:documentCopyPath];
            }
        }
        
        if (!fileUrl)
        {
            // Use the cached file by default
            fileUrl = [NSURL fileURLWithPath:_cacheFilePath];
        }
        
        onReadyToShare (fileUrl);
        
    } failure:onFailure];
}

- (void)onShareEnded
{
    // Remove the temporary file created to prepare attachment sharing
    if (documentCopyPath)
    {
        [[NSFileManager defaultManager] removeItemAtPath:documentCopyPath error:nil];
        documentCopyPath = nil;
    }
}

@end
