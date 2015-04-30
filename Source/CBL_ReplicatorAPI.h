//
//  CBL_ReplicatorAPI.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 4/30/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
@class CBLDatabase, CBL_Revision, CBL_RevisionList, CBLCookieStorage;
@protocol CBLAuthorizer;


typedef CBL_Revision* (^RevisionBodyTransformationBlock)(CBL_Revision*);


/** Posted when changesProcessed or changesTotal changes. */
extern NSString* CBL_ReplicatorProgressChangedNotification;

/** Posted when replicator stops running. */
extern NSString* CBL_ReplicatorStoppedNotification;


/** Protocol that replicator implementations must implement. */
@protocol CBL_ReplicatorAPI <NSObject>

@property (weak, readonly) CBLDatabase* db;
@property (readonly) NSURL* remote;
@property (readonly) BOOL isPush;
@property (readonly) BOOL continuous;
@property (readonly) CBLCookieStorage* cookieStorage;
@property (copy) NSString* filterName;
@property (copy) NSDictionary* filterParameters;
@property (copy) NSArray *docIDs;
@property (copy) NSDictionary* options;

@property (readonly) NSString* remoteCheckpointDocID;

/** Optional dictionary of headers to be added to all requests to remote servers. */
@property (copy) NSDictionary* requestHeaders;

@property (strong) id<CBLAuthorizer> authorizer;

/** Hook for transforming document body, e.g., encryption and decryption during replication */
@property (strong, nonatomic) RevisionBodyTransformationBlock revisionBodyTransformationBlock;

/** Is the replicator running? (Observable) */
@property (readonly, nonatomic) BOOL running;

/** Is the replicator able to connect to the remote host? */
@property (readonly, nonatomic) BOOL online;

/** Is the replicator actively sending/receiving revisions? (Observable) */
@property (readonly, nonatomic) BOOL active;

/** Latest error encountered while replicating.
    This is set to nil when starting. It may also be set to nil by the client if desired.
    Not all errors are fatal; if .running is still true, the replicator will retry. */
@property (strong, nonatomic) NSError* error;

/** Number of changes (docs or other metadata) transferred so far. */
@property (readonly, nonatomic) NSUInteger changesProcessed;

/** Approximate total number of changes to transfer.
    This is only an estimate and its value will change during replication. It starts at zero and returns to zero when replication stops. */
@property (readonly, nonatomic) NSUInteger changesTotal;

/** JSON-compatible dictionary of task info, as seen in _active_tasks REST API */
@property (readonly) NSDictionary* activeTaskInfo;

@property (readonly) SecCertificateRef serverCert;

/** A unique-per-process string identifying this replicator instance. */
@property (copy, nonatomic) NSString* sessionID;

/** Starts the replicator.
    Replicators run asynchronously so nothing will happen until later.
    A replicator can only be started once; don't reuse it after it stops. */
- (void) start;

/** Request to stop the replicator.
    Any pending asynchronous operations will be canceled.
    CBL_ReplicatorStoppedNotification will be posted when it finally stops. */
- (void) stop;

/** Setting suspended to YES pauses the replicator. */
@property (nonatomic) BOOL suspended;

/** Called by CBLDatabase to notify active replicators that it's about to close. */
- (void) databaseClosing;

@optional
@property BOOL createTarget;
@property (readonly) NSSet* pendingDocIDs;
@end



@protocol CBL_ReplicatorFactory <NSObject>
- (id<CBL_ReplicatorAPI>) replicatorWithDB: (CBLDatabase*)db
                                    remote: (NSURL*)remote
                                      push: (BOOL)push
                                continuous: (BOOL)continuous;
@end


// Supported keys in the .options dictionary:
#define kCBLReplicatorOption_Reset @"reset"
#define kCBLReplicatorOption_Timeout @"connection_timeout"  // CouchDB specifies this name
#define kCBLReplicatorOption_Heartbeat @"heartbeat"         // NSNumber, in ms
#define kCBLReplicatorOption_PollInterval @"poll"           // NSNumber, in ms
#define kCBLReplicatorOption_Network @"network"             // "WiFi" or "Cell"
#define kCBLReplicatorOption_UseWebSocket @"websocket"      // Boolean; default is YES
#define kCBLReplicatorOption_PinnedCert @"pinnedCert"       // NSData or (hex) NSString

// Boolean; default is YES. Setting this option will have no effect and result to always 'trust' if
// the kCBLReplicatorOption_Network option is also set.
#define kCBLReplicatorOption_TrustReachability @"trust_reachability"
