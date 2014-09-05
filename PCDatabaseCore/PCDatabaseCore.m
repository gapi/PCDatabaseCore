//
//  PCDatabaseCore.m
//  PCDatabaseCore
//
//  Created by Paweł Nużka on 02/09/14.
//  Copyright (c) 2014 Pilot. All rights reserved.
//

#import "PCDatabaseCore.h"
#import "NSManagedObjectModel+KCOrderedAccessorFix.h"
#import "UIApplication+Directories.h"

@interface PCDatabaseCore ()
@property (nonatomic, strong) dispatch_queue_t taskQ;
@property (nonatomic, strong) NSString *databaseName;
@end

const int kFetchBatchSize = 10;
const int kSaveBatchSize = 1000;

static NSString *kDatabaseName = @"DatabaseName";
static NSString *kDatabaseType = @"sqlite";

@implementation PCDatabaseCore
@synthesize mainObjectContext, backgroundObjectContext, managedObjectModel, writerObjectContext, persistentStoreCoordinator;

//////////////////////////////////////////////////////
#pragma mark Initialization
+ (instancetype)sharedInstance
{
    
#ifdef TEST
    return [self sharedInstanceTest];
#endif
    static dispatch_once_t onceToken;
    static id dbSharedInstance;
    dispatch_once(&onceToken, ^{
        dbSharedInstance = [[[self class] alloc] init];
        [dbSharedInstance mainObjectContext];
        [dbSharedInstance setDatabaseName:kDatabaseName];
    });
    return dbSharedInstance;
}

+ (instancetype)sharedInstanceTest
{
    static dispatch_once_t onceToken;
    static id dbSharedTestInstance;
    dispatch_once(&onceToken, ^{
        kDatabaseName = @"XCTests";
        dbSharedTestInstance = [[[self class] alloc] init];
    });
    return dbSharedTestInstance;
}

- (void)prepareForTests
{
    NSArray *bundles = [NSArray arrayWithObject:[NSBundle bundleForClass:[self class]]];
    NSManagedObjectModel *mom = [NSManagedObjectModel mergedModelFromBundles:bundles];
    
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:mom];
    self.persistentStoreCoordinator = psc;
}

- (id)init
{
    self = [super init];
    if (self) {
        NSString *queueName = [NSString stringWithFormat:@"%@.%@.Database",[[NSBundle mainBundle] bundleIdentifier], kDatabaseName];
        self.taskQ = dispatch_queue_create([queueName cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
/////////////////////////////////////////////////////////////////
#pragma mark - Getters & Setters
- (NSString *)databaseName
{
    if (_databaseName != nil)
        return _databaseName;
    
    _databaseName = [NSString stringWithFormat:@"%@.%@", kDatabaseName, kDatabaseType];
    return _databaseName;
}

- (NSString *)databasePath
{
    return [[[UIApplication sharedApplication]  applicationDocumentsDirectory] stringByAppendingPathComponent:self.databaseName];
}
- (NSManagedObjectContext *)mainObjectContext
{
    if (mainObjectContext != nil)
    {
        return mainObjectContext;
    }
    
    mainObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    [mainObjectContext setParentContext:self.writerObjectContext];
    [mainObjectContext setUndoManager:nil];
    return mainObjectContext;
}

- (NSManagedObjectContext *)writerObjectContext
{
    if (writerObjectContext != nil)
        return writerObjectContext;
    
    
    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
    if (coordinator != nil)
    {
        writerObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
        [writerObjectContext setPersistentStoreCoordinator:coordinator];
        [writerObjectContext setUndoManager:nil];
    }
    return writerObjectContext;
}


- (NSManagedObjectContext *)backgroundObjectContext
{
    if (backgroundObjectContext != nil)
        return backgroundObjectContext;
    
    backgroundObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    [backgroundObjectContext setParentContext:[self mainObjectContext]];
    [backgroundObjectContext setUndoManager:nil];
    return backgroundObjectContext;
}

- (NSManagedObjectModel *)managedObjectModel
{
    if (managedObjectModel != nil)
    {
        return managedObjectModel;
    }
    managedObjectModel = [NSManagedObjectModel mergedModelFromBundles:nil];
    [managedObjectModel kc_generateOrderedSetAccessors];
    return managedObjectModel;
}


- (void)setPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)_persistentStoreCoordinator
{
    if (!persistentStoreCoordinator)
        persistentStoreCoordinator = _persistentStoreCoordinator;
}

- (NSString *)applicationDocumentsDirectory
{
    NSString *libraryDirectory = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) lastObject];
    return [NSString stringWithFormat:@"%@/Caches", libraryDirectory];
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (persistentStoreCoordinator != nil)
    {
        return persistentStoreCoordinator;
    }
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
    NSString *storePath = [[self applicationDocumentsDirectory]
                           stringByAppendingPathComponent: [self databaseName]];
    NSURL *storeUrl = [NSURL fileURLWithPath:storePath];
    [storeUrl setResourceValue:@(NO) forKey:@"NSURLIsExcludedFromBackupKey" error:nil];
    
    if (![fileManager fileExistsAtPath:storePath]) {
        // Put down default database if one doesn't already exist
        NSString *defaultStorePath = [[NSBundle mainBundle] pathForResource:self.databaseName
                                                                     ofType:kDatabaseType];
        if (defaultStorePath) {
            [fileManager copyItemAtPath:defaultStorePath toPath:storePath error:NULL];
        }
    }

    NSError *error = nil;
    NSDictionary *options = nil;
#if DEBUG
    options = @{ NSSQLitePragmasOption : @{@"journal_mode" : @"DELETE"} };
#endif
    persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:self.managedObjectModel];
    if (![persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:storeUrl options:options error:&error])
    {
                return nil;
    }
    
    return persistentStoreCoordinator;
}

#pragma mark - ContextDidSaveNotification
- (void)contextChanged:(NSNotification *)notification
{
    UIApplication* app = [UIApplication sharedApplication];
    __block UIBackgroundTaskIdentifier bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        [app endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    
    if ([notification object] == [self mainObjectContext]) return;
    
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread:@selector(contextChanged:) withObject:notification waitUntilDone:YES];
        return;
    }
        [[self mainObjectContext] mergeChangesFromContextDidSaveNotification:notification];
    bgTask = UIBackgroundTaskInvalid;
    [self fixNSFetchedResultControllerForNotification:notification];
}

- (void)fixNSFetchedResultControllerForNotification:(NSNotification *)notification
{
    [self makeNSFeetchedResultControllersWorksWithObjects:[[notification userInfo] objectForKey:NSUpdatedObjectsKey]];
    [self makeNSFeetchedResultControllersWorksWithObjects:[[notification userInfo] objectForKey:NSDeletedObjectsKey]];
    [self makeNSFeetchedResultControllersWorksWithObjects:[[notification userInfo] objectForKey:NSInsertedObjectsKey]];
    [self makeNSFeetchedResultControllersWorksWithObjects:[[notification userInfo] objectForKey:NSRefreshedObjectsKey]];
}

/*
 * fix from: http://stackoverflow.com/questions/14018068/nsfetchedresultscontroller-doesnt-call-controllerdidchangecontent-after-update
 */
- (void)makeNSFeetchedResultControllersWorksWithObjects:(NSArray *)newObjectsInMainContext
{
    for(NSManagedObject *object in newObjectsInMainContext) {
        NSManagedObject *obj = [[self mainObjectContext] existingObjectWithID:[object objectID]
                                                                        error:nil];
        
        @try {
            [obj willAccessValueForKey:nil];
        }
        @catch (NSException *exception) {
                    }
    }
}

#pragma mark - Threads support
- (void)setStoreInManagedObjectContext:(NSManagedObjectContext *)mcontext
{
    [mcontext setPersistentStoreCoordinator:self.persistentStoreCoordinator];
}

- (void)removeManagedObjectContext:(NSManagedObjectContext *)mcontext
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSManagedObjectContextDidSaveNotification object:mcontext];
}
- (NSArray *)objectsFromBackgroundThread:(NSArray *)objects
{
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:objects.count];
    for (NSManagedObject * object in objects)
        [result addObject:[self.mainObjectContext objectWithID:object.objectID]];
    return result;
}

- (id)objectFromBackgroundThread:(NSManagedObject *)object
{
    if (!object)
        return nil;
    return [self.mainObjectContext objectWithID:object.objectID];
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - API Methods
//**Saving database
- (NSError *)saveDatabase
{
    __block NSError *error = nil;
    [mainObjectContext performBlockAndWait:^{
        if ([mainObjectContext save:&error])
        {
            [self.writerObjectContext performBlockAndWait:^{
                if (![self.writerObjectContext save:&error])
                {
                                    }
            }];
        }
    }];
    return error;
}


@end