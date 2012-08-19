//
//  PCOManagedObjectLoader.m
//  RestKit
//
//  Created by Jason on 8/17/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//

#import "PCOManagedObjectLoader.h"

#import "RKObjectMapper.h"
#import "RKObjectManager.h"
#import "RKManagedObjectStore.h"

#import "RKObjectMapperError.h"
#import "Errors.h"
#import "RKNotifications.h"
#import "RKParser.h"
#import "RKObjectLoader_Internals.h"
#import "RKParserRegistry.h"
#import "RKRequest_Internals.h"
#import "RKObjectSerializer.h"

#import "RKURL.h"
#import "NSManagedObject+ActiveRecord.h"
#import "RKLog.h"

@implementation PCOManagedObjectLoader


+ (id)loaderWithResourcePath:(NSString*)resourcePath objectManager:(RKObjectManager*)objectManager delegate:(id<PCOManagedObjectLoaderDelegate>)delegate {
    return [[[self alloc] initWithResourcePath:resourcePath objectManager:objectManager delegate:delegate] autorelease];
}

- (id)initWithResourcePath:(NSString*)resourcePath objectManager:(RKObjectManager*)objectManager delegate:(id<PCOManagedObjectLoaderDelegate>)delegate {
	if ((self = [super initWithURL:[objectManager.client URLForResourcePath:resourcePath] delegate:delegate])) {
        _objectManager = objectManager;
        [self.objectManager.client setupRequest:self];
	}

	return self;
}


#pragma mark - Response Processing

// NOTE: This method is significant because the notifications posted are used by
// RKRequestQueue to remove requests from the queue. All requests need to be finalized.
- (void)finalizeLoad:(BOOL)successful error:(NSError*)error {
	_isLoading = NO;

	if (successful) {
		_isLoaded = YES;
        if ([self.delegate respondsToSelector:@selector(objectLoaderDidFinishLoading:)]) {
            [(NSObject<PCOManagedObjectLoaderDelegate>*)self.delegate performSelectorOnMainThread:@selector(objectLoaderDidFinishLoading:)
                                                                               withObject:self waitUntilDone:YES];
        }

		NSDictionary* userInfo = [NSDictionary dictionaryWithObject:_response
                                                             forKey:RKRequestDidLoadResponseNotificationUserInfoResponseKey];
        [[NSNotificationCenter defaultCenter] postNotificationName:RKRequestDidLoadResponseNotification
                                                            object:self
                                                          userInfo:userInfo];
	} else {
        NSDictionary* userInfo = [NSDictionary dictionaryWithObject:(error ? error : (NSError*)[NSNull null])
                                                             forKey:RKRequestDidFailWithErrorNotificationUserInfoErrorKey];
		[[NSNotificationCenter defaultCenter] postNotificationName:RKRequestDidFailWithErrorNotification
															object:self
														  userInfo:userInfo];
	}
}

// Invoked on the main thread. Inform the delegate.
- (void)informDelegateOfObjectLoadWithResultDictionary:(NSDictionary*)resultDictionary {
    NSAssert([NSThread isMainThread], @"RKObjectLoaderDelegate callbacks must occur on the main thread");

	RKObjectMappingResult* result = [RKObjectMappingResult mappingResultWithDictionary:resultDictionary];

    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObjectDictionary:)]) {
        [(NSObject<PCOManagedObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObjectDictionary:[result asDictionary]];
    }

    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObjects:)]) {
        [(NSObject<PCOManagedObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObjects:[result asCollection]];
    }

    if ([self.delegate respondsToSelector:@selector(objectLoader:didLoadObject:)]) {
        [(NSObject<PCOManagedObjectLoaderDelegate>*)self.delegate objectLoader:self didLoadObject:[result asObject]];
    }

	RKLogTrace(@"Object loader finished");

	[self finalizeLoad:YES error:nil];
}

#pragma mark - Response Object Mapping

- (RKObjectMappingResult*)mapResponseWithMappingProvider:(RKObjectMappingProvider*)mappingProvider toObject:(id)targetObject error:(NSError**)error {
    id<RKParser> parser = [[RKParserRegistry sharedRegistry] parserForMIMEType:self.response.MIMEType];
    NSAssert1(parser, @"Cannot perform object load without a parser for MIME Type '%@'", self.response.MIMEType);

    // Check that there is actually content in the response body for mapping. It is possible to get back a 200 response
    // with the appropriate MIME Type with no content (such as for a successful PUT or DELETE). Make sure we don't generate an error
    // in these cases
    id bodyAsString = [self.response bodyAsString];
    if (bodyAsString == nil || [[bodyAsString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) {
        RKLogDebug(@"Mapping attempted on empty response body...");
        if (self.targetObject) {
            return [RKObjectMappingResult mappingResultWithDictionary:[NSDictionary dictionaryWithObject:self.targetObject forKey:@""]];
        }

        return [RKObjectMappingResult mappingResultWithDictionary:[NSDictionary dictionary]];
    }

    id parsedData = [parser objectFromString:bodyAsString error:error];
    if (parsedData == nil && error) {
        return nil;
    }

    // Allow the delegate to manipulate the data
    if ([self.delegate respondsToSelector:@selector(objectLoader:willMapData:)]) {
        parsedData = [[parsedData mutableCopy] autorelease];
        [(NSObject<PCOManagedObjectLoaderDelegate>*)self.delegate objectLoader:self willMapData:&parsedData];
    }

    RKObjectMapper* mapper = [RKObjectMapper mapperWithObject:parsedData mappingProvider:mappingProvider inContext:_backgroundThreadManagedObjectContext];
    mapper.targetObject = targetObject;
    mapper.delegate = self;
    RKObjectMappingResult* result = [mapper performMapping];

    // Log any mapping errors
    if (mapper.errorCount > 0) {
        RKLogError(@"Encountered errors during mapping: %@", [[mapper.errors valueForKey:@"localizedDescription"] componentsJoinedByString:@", "]);
    }

    // The object mapper will return a nil result if mapping failed
    if (nil == result) {
        // TODO: Construct a composite error that wraps up all the other errors. Should probably make it performMapping:&error when we have this?
        if (error) *error = [mapper.errors lastObject];
        return nil;
    }

    return result;
}

- (RKObjectMappingResult*)performMapping:(NSError**)error {
    NSAssert(_sentSynchronously || ![NSThread isMainThread], @"Mapping should occur on a background thread");

	_backgroundThreadManagedObjectContext = [_objectManager.objectStore newManagedObjectContext];
	
    RKObjectMappingProvider* mappingProvider;
    if (self.objectMapping) {
        NSString* rootKeyPath = self.objectMapping.rootKeyPath ? self.objectMapping.rootKeyPath : @"";
        RKLogDebug(@"Found directly configured object mapping, creating temporary mapping provider for keyPath %@", rootKeyPath);
        mappingProvider = [[RKObjectMappingProvider new] autorelease];
        [mappingProvider setMapping:self.objectMapping forKeyPath:rootKeyPath];
    } else {
        RKLogDebug(@"No object mapping provider, using mapping provider from parent object manager to perform KVC mapping");
        mappingProvider = self.objectManager.mappingProvider;
    }

	[_backgroundThreadManagedObjectContext save:error];

    return [self mapResponseWithMappingProvider:mappingProvider toObject:self.targetObject error:error];
}



- (BOOL)canParseMIMEType:(NSString*)MIMEType {
    if ([[RKParserRegistry sharedRegistry] parserForMIMEType:self.response.MIMEType]) {
        return YES;
    }

    RKLogWarning(@"Unable to find parser for MIME Type '%@'", MIMEType);
    return NO;
}

- (BOOL)isResponseMappable {
    if ([self.response isServiceUnavailable]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:RKServiceDidBecomeUnavailableNotification object:self];
    }

	if ([self.response isFailure]) {
		[(NSObject<PCOManagedObjectLoaderDelegate>*)_delegate objectLoader:self didFailWithError:self.response.failureError];

		[self finalizeLoad:NO error:self.response.failureError];

		return NO;
    } else if ([self.response isNoContent]) {
        // The No Content (204) response will never have a message body or a MIME Type. Invoke the delegate with self
        [self informDelegateOfObjectLoadWithResultDictionary:[NSDictionary dictionaryWithObject:self forKey:@""]];
        return NO;
	} else if (NO == [self canParseMIMEType:[self.response MIMEType]]) {
        // We can't parse the response, it's unmappable regardless of the status code
        RKLogWarning(@"Encountered unexpected response with status code: %ld (MIME Type: %@)", (long) self.response.statusCode, self.response.MIMEType);
        NSError* error = [NSError errorWithDomain:RKRestKitErrorDomain code:RKObjectLoaderUnexpectedResponseError userInfo:nil];
        if ([_delegate respondsToSelector:@selector(objectLoaderDidLoadUnexpectedResponse:)]) {
            [(NSObject<PCOManagedObjectLoaderDelegate>*)_delegate objectLoaderDidLoadUnexpectedResponse:self];
        } else {
            [(NSObject<PCOManagedObjectLoaderDelegate>*)_delegate objectLoader:self didFailWithError:error];
        }

        // NOTE: We skip didFailLoadWithError: here so that we don't send the delegate
        // conflicting messages around unexpected response and failure with error
        [self finalizeLoad:NO error:error];

        return NO;
    } else if ([self.response isError]) {
        // This is an error and we can map the MIME Type of the response
        [self handleResponseError];
		return NO;
    }

	return YES;
}


#pragma mark - RKRequest & RKRequestDelegate methods


- (void)didFailLoadWithError:(NSError*)error {
    @autoreleasepool {

		if ([_delegate respondsToSelector:@selector(request:didFailLoadWithError:)]) {
            [_delegate request:self didFailLoadWithError:error];
        }

        [(NSObject<PCOManagedObjectLoaderDelegate>*)_delegate objectLoader:self didFailWithError:error];

        [self finalizeLoad:NO error:error];

	}
}

// NOTE: We do NOT call super here. We are overloading the default behavior from RKRequest
- (void)didFinishLoad:(RKResponse*)response {
    NSAssert([NSThread isMainThread], @"RKObjectLoaderDelegate callbacks must occur on the main thread");
	_response = [response retain];


    if ([_delegate respondsToSelector:@selector(request:didLoadResponse:)]) {
        [_delegate request:self didLoadResponse:_response];
    }

	if ([self isResponseMappable]) {
        // Determine if we are synchronous here or not.
        if (_sentSynchronously) {
            NSError* error = nil;
            _result = [[self performMapping:&error] retain];
            if (self.result) {
                [self processMappingResult:self.result];
            } else {
                [self performSelectorInBackground:@selector(didFailLoadWithError:) withObject:error];
            }
        } else {
            [self performSelectorInBackground:@selector(performMappingOnBackgroundThread) withObject:nil];
        }
	}
}






- (id)init {
    self = [super init];
    if (self) {
        _managedObjectKeyPaths = [[NSMutableSet alloc] init];
    }
    return self;
}

- (void)dealloc
{
	// Weak reference
    _objectManager = nil;

    [_sourceObject release];
    _sourceObject = nil;
	[_targetObject release];
	_targetObject = nil;
	[_response release];
	_response = nil;
	[_objectMapping release];
	_objectMapping = nil;
    [_result release];
    _result = nil;
    [_serializationMIMEType release];
    [_serializationMapping release];


    [_targetObjectID release];
    _targetObjectID = nil;
    _deleteObjectOnFailure = NO;
    [_managedObjectKeyPaths release];

    [super dealloc];
}

- (void)reset {
    [super reset];
    [_targetObjectID release];
    _targetObjectID = nil;

	[_response release];
    _response = nil;
    [_result release];
    _result = nil;
}

- (RKManagedObjectStore*)objectStore {
    return self.objectManager.objectStore;
}

#pragma mark - RKObjectMapperDelegate methods

- (void)objectMapper:(RKObjectMapper*)objectMapper didMapFromObject:(id)sourceObject toObject:(id)destinationObject atKeyPath:(NSString*)keyPath usingMapping:(PCOManagedObjectMapping*)objectMapping {
    if ([destinationObject isKindOfClass:[NSManagedObject class]]) {
        [_managedObjectKeyPaths addObject:keyPath];
    }
}

#pragma mark - PCOManagedObjectLoader overrides

// Overload the target object reader to return a thread-local copy of the target object
- (id)targetObject {
    if ([NSThread isMainThread] == NO && _targetObjectID) {
        return [_backgroundThreadManagedObjectContext objectWithID:_targetObjectID];
    }

    return _targetObject;
}

- (void)setTargetObject:(NSObject*)targetObject {
    [_targetObject release];
    _targetObject = nil;
    _targetObject = [targetObject retain];

    [_targetObjectID release];
    _targetObjectID = nil;
}

- (BOOL)prepareURLRequest
{
    // TODO: Can we just do this if the object hasn't been saved already???

    // NOTE: There is an important sequencing issue here. You MUST save the
    // managed object context before retaining the objectID or you will run
    // into an error where the object context cannot be saved. We do this
    // right before send to avoid sequencing issues where the target object is
    // set before the managed object store.
    if (self.targetObject && [self.targetObject isKindOfClass:[NSManagedObject class]]) {
        _deleteObjectOnFailure = [(NSManagedObject*)self.targetObject isNew];
        //[self.objectStore save];
		[_backgroundThreadManagedObjectContext save:nil];
		_targetObjectID = [[(NSManagedObject*)self.targetObject objectID] retain];
    }

	if ((self.sourceObject && self.params == nil) && (self.method == RKRequestMethodPOST || self.method == RKRequestMethodPUT)) {
        NSAssert(self.serializationMapping, @"You must provide a serialization mapping for objects of type '%@'", NSStringFromClass([self.sourceObject class]));
        RKLogDebug(@"POST or PUT request for source object %@, serializing to MIME Type %@ for transport...", self.sourceObject, self.serializationMIMEType);
        RKObjectSerializer* serializer = [RKObjectSerializer serializerWithObject:self.sourceObject mapping:self.serializationMapping];
        NSError* error = nil;
        id params = [serializer serializationForMIMEType:self.serializationMIMEType error:&error];

        if (error) {
            RKLogError(@"Serializing failed for source object %@ to MIME Type %@: %@", self.sourceObject, self.serializationMIMEType, [error localizedDescription]);
            [self didFailLoadWithError:error];
            return NO;
        }

        self.params = params;
    }

    // TODO: This is an informal protocol ATM. Maybe its not obvious enough?
    if (self.sourceObject) {
        if ([self.sourceObject respondsToSelector:@selector(willSendWithObjectLoader:)]) {
            [self.sourceObject performSelector:@selector(willSendWithObjectLoader:) withObject:self];
        }
    }

    return [super prepareURLRequest];
}

- (void)deleteCachedObjectsMissingFromResult:(RKObjectMappingResult*)result {
    if (! [self isGET]) {
        RKLogDebug(@"Skipping cleanup of objects via managed object cache: only used for GET requests.");
        return;
    }

    if ([self.URL isKindOfClass:[RKURL class]]) {
        //RKURL* rkURL = (RKURL*)self.URL;

        //NSArray* results = [result asCollection];
        //NSArray* cachedObjects = [self.objectStore objectsForResourcePath:rkURL.resourcePath];
        //NSObject<RKManagedObjectCache>* managedObjectCache = self.objectStore.managedObjectCache;
        //BOOL queryForDeletion = [managedObjectCache respondsToSelector:@selector(shouldDeleteOrphanedObject:)];
		/*
		 for (id object in cachedObjects) {
		 if (NO == [results containsObject:object]) {
		 if (queryForDeletion && [managedObjectCache shouldDeleteOrphanedObject:object] == NO)
		 {
		 RKLogTrace(@"Sparing orphaned object %@ even though not returned in result set", object);
		 }
		 else
		 {
		 RKLogTrace(@"Deleting orphaned object %@: not found in result set and expected at this resource path", object);
		 [[self.objectStore managedObjectContext] deleteObject:object];
		 }
		 }
		 }
		 */
    } else {
        RKLogWarning(@"Unable to perform cleanup of server-side object deletions: unable to determine resource path.");
    }

}

// NOTE: We are on the background thread here, be mindful of Core Data's threading needs
- (void)processMappingResult:(RKObjectMappingResult*)result {
    NSAssert(_sentSynchronously || ![NSThread isMainThread], @"Mapping result processing should occur on a background thread");

	if (_targetObjectID && self.targetObject && self.method == RKRequestMethodDELETE) {
        NSManagedObject* backgroundThreadObject = [_backgroundThreadManagedObjectContext objectWithID:_targetObjectID];
        RKLogInfo(@"Deleting local object %@ due to DELETE request", backgroundThreadObject);
        [_backgroundThreadManagedObjectContext deleteObject:backgroundThreadObject];
    }

    // If the response was successful, save the store...
    if ([self.response isSuccessful]) {
        //[self deleteCachedObjectsMissingFromResult:result];
        NSError* error = nil;
		[_backgroundThreadManagedObjectContext save:&error];
        if (error) {
            RKLogError(@"Failed to save managed object context after mapping completed: %@", [error localizedDescription]);

			if (self.delegate)
			{
				/*
				NSMethodSignature* signature = [self.delegate methodSignatureForSelector:@selector(objectLoader:didFailWithError:)];
				RKManagedObjectThreadSafeInvocation* invocation = [RKManagedObjectThreadSafeInvocation invocationWithMethodSignature:signature];
				[invocation setTarget:self.delegate];
				[invocation setSelector:@selector(objectLoader:didFailWithError:)];
				[invocation setArgument:&self atIndex:2];
				[invocation setArgument:&error atIndex:3];
				[invocation invokeOnMainThread];
				*/

				dispatch_async(dispatch_get_main_queue(), ^{

					[(NSObject<PCOManagedObjectLoaderDelegate> *)self.delegate objectLoader:self didFailWithError:error];

				});

			}

            return;
        }
    }

	if (self.delegate)
	{
		NSDictionary* dictionary = [result asDictionary];
		
		dispatch_async(dispatch_get_main_queue(), ^{

			[self informDelegateOfObjectLoadWithResultDictionary:dictionary];

		});
	}

}

// Overloaded to handle deleting an object orphaned by a failed postObject:
- (void)handleResponseError
{
	// Since we are mapping what we know to be an error response, we don't want to map the result back onto our
    // target object
    NSError* error = nil;
    RKObjectMappingResult* result = [self mapResponseWithMappingProvider:self.objectManager.mappingProvider toObject:nil error:&error];
    if (result) {
        error = [result asError];
    } else {
        RKLogError(@"Encountered an error while attempting to map server side errors from payload: %@", [error localizedDescription]);
    }

    [(NSObject<PCOManagedObjectLoaderDelegate>*)_delegate objectLoader:self didFailWithError:error];
    [self finalizeLoad:NO error:error];


    if (_targetObjectID) {
        if (_deleteObjectOnFailure) {
            RKLogInfo(@"Error response encountered: Deleting existing managed object with ID: %@", _targetObjectID);
            NSManagedObject* objectToDelete = [_backgroundThreadManagedObjectContext objectWithID:_targetObjectID];
            if (objectToDelete) {
                [_backgroundThreadManagedObjectContext deleteObject:objectToDelete];
                [_backgroundThreadManagedObjectContext save:&error];
            } else {
                RKLogWarning(@"Unable to delete existing managed object with ID: %@. Object not found in the store.", _targetObjectID);
            }
        } else {
            RKLogDebug(@"Skipping deletion of existing managed object");
        }
    }
}


- (void)performMappingOnBackgroundThread
{
	if (self.objectStore)
	{
		@autoreleasepool {

			if (self.delegate)
			{
				NSError* error = nil;
				_result = [[self performMapping:&error] retain];
				NSAssert(_result || error, @"Expected performMapping to return a mapping result or an error.");
				if (self.result) {
					[self processMappingResult:self.result];
				} else if (error) {
					[self didFailLoadWithError:error];
				}
			}

		}
	}
}



@end
