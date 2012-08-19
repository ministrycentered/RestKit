//
//  PCOManagedObjectMappingOperation.m
//  RestKit
//
//  Created by Jason on 8/18/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//

#import <objc/message.h>
#import "PCOManagedObjectMappingOperation.h"

#import "PCOManagedObjectMapping.h"
#import "NSManagedObject+ActiveRecord.h"
#import "RKLog.h"

#import "RKObjectManager.h"
#import "RKManagedObjectStore.h"

#import "RKDynamicObjectMapping.h"


// Temporary home for object equivalancy tests
BOOL RKObjectIsValueEqualToValue(id sourceValue, id destinationValue);
BOOL RKObjectIsValueEqualToValue(id sourceValue, id destinationValue) {
    NSCAssert(sourceValue, @"Expected sourceValue not to be nil");
    NSCAssert(destinationValue, @"Expected destinationValue not to be nil");

    SEL comparisonSelector;
    if ([sourceValue isKindOfClass:[NSString class]] && [destinationValue isKindOfClass:[NSString class]]) {
        comparisonSelector = @selector(isEqualToString:);
    } else if ([sourceValue isKindOfClass:[NSNumber class]] && [destinationValue isKindOfClass:[NSNumber class]]) {
        comparisonSelector = @selector(isEqualToNumber:);
    } else if ([sourceValue isKindOfClass:[NSDate class]] && [destinationValue isKindOfClass:[NSDate class]]) {
        comparisonSelector = @selector(isEqualToDate:);
    } else if ([sourceValue isKindOfClass:[NSArray class]] && [destinationValue isKindOfClass:[NSArray class]]) {
        comparisonSelector = @selector(isEqualToArray:);
    } else if ([sourceValue isKindOfClass:[NSDictionary class]] && [destinationValue isKindOfClass:[NSDictionary class]]) {
        comparisonSelector = @selector(isEqualToDictionary:);
    } else if ([sourceValue isKindOfClass:[NSSet class]] && [destinationValue isKindOfClass:[NSSet class]]) {
        comparisonSelector = @selector(isEqualToSet:);
    } else {
        comparisonSelector = @selector(isEqual:);
    }

    // Comparison magic using function pointers. See this page for details: http://www.red-sweater.com/blog/320/abusing-objective-c-with-class
    // Original code courtesy of Greg Parker
    // This is necessary because isEqualToNumber will return negative integer values that aren't coercable directly to BOOL's without help [sbw]
    BOOL (*ComparisonSender)(id, SEL, id) = (BOOL (*)(id, SEL, id)) objc_msgSend;
    return ComparisonSender(sourceValue, comparisonSelector, destinationValue);
}


@implementation PCOManagedObjectMappingOperation

+ (id)mappingOperationFromObject:(id)sourceObject toObject:(id)destinationObject withMapping:(id<RKObjectMappingDefinition>)objectMapping {
    // Check for availability of ManagedObjectMappingOperation. Better approach for handling?
    Class targetClass = [PCOManagedObjectMappingOperation class];

    return [[[targetClass alloc] initWithSourceObject:sourceObject destinationObject:destinationObject mapping:objectMapping] autorelease];
}

- (id)initWithSourceObject:(id)sourceObject destinationObject:(id)destinationObject mapping:(id<RKObjectMappingDefinition>)objectMapping {
    NSAssert(sourceObject != nil, @"Cannot perform a mapping operation without a sourceObject object");
    NSAssert(destinationObject != nil, @"Cannot perform a mapping operation without a destinationObject");
    NSAssert(objectMapping != nil, @"Cannot perform a mapping operation without a mapping");

    self = [super init];
    if (self) {
        _sourceObject = [sourceObject retain];
        _destinationObject = [destinationObject retain];
		
        if ([objectMapping isKindOfClass:[PCOManagedObjectMappingOperation class]]) {
            _objectMapping = [[(RKDynamicObjectMapping*)objectMapping objectMappingForDictionary:_sourceObject] retain];
            RKLogDebug(@"RKObjectMappingOperation was initialized with a dynamic mapping. Determined concrete mapping = %@", _objectMapping);
        } else if ([objectMapping isKindOfClass:[PCOManagedObjectMapping class]]) {
            _objectMapping = (PCOManagedObjectMapping*)[objectMapping retain];
        }
        NSAssert(_objectMapping, @"Cannot perform a mapping operation with an object mapping");
    }

    return self;
}

- (void)dealloc {
    [_sourceObject release];
    [_destinationObject release];
    [_objectMapping release];
    [_nestedAttributeSubstitution release];
    [_queue release];

    [super dealloc];
}

- (NSDate*)parseDateFromString:(NSString*)string {
    RKLogTrace(@"Transforming string value '%@' to NSDate...", string);

	NSDate* date = nil;
    for (NSDateFormatter *dateFormatter in self.objectMapping.dateFormatters) {
        @synchronized(dateFormatter) {
            date = [dateFormatter dateFromString:string];
        }
        if (date) {
			break;
		}
    }

    return date;
}

- (id)transformValue:(id)value atKeyPath:keyPath toType:(Class)destinationType {
    RKLogTrace(@"Found transformable value at keyPath '%@'. Transforming from type '%@' to '%@'", keyPath, NSStringFromClass([value class]), NSStringFromClass(destinationType));
    Class sourceType = [value class];
    Class orderedSetClass = NSClassFromString(@"NSOrderedSet");

    if ([sourceType isSubclassOfClass:[NSString class]]) {
        if ([destinationType isSubclassOfClass:[NSDate class]]) {
            // String -> Date
            return [self parseDateFromString:(NSString*)value];
        } else if ([destinationType isSubclassOfClass:[NSURL class]]) {
            // String -> URL
            return [NSURL URLWithString:(NSString*)value];
        } else if ([destinationType isSubclassOfClass:[NSDecimalNumber class]]) {
            // String -> Decimal Number
            return [NSDecimalNumber decimalNumberWithString:(NSString*)value];
        } else if ([destinationType isSubclassOfClass:[NSNumber class]]) {
            // String -> Number
            NSString* lowercasedString = [(NSString*)value lowercaseString];
            NSSet* trueStrings = [NSSet setWithObjects:@"true", @"t", @"yes", nil];
            NSSet* booleanStrings = [trueStrings setByAddingObjectsFromSet:[NSSet setWithObjects:@"false", @"f", @"no", nil]];
            if ([booleanStrings containsObject:lowercasedString]) {
                // Handle booleans encoded as Strings
                return [NSNumber numberWithBool:[trueStrings containsObject:lowercasedString]];
            } else {
                return [NSNumber numberWithDouble:[(NSString*)value doubleValue]];
            }
        }
    } else if (value == [NSNull null] || [value isEqual:[NSNull null]]) {
        // Transform NSNull -> nil for simplicity
        return nil;
    } else if ([sourceType isSubclassOfClass:[NSSet class]]) {
        // Set -> Array
        if ([destinationType isSubclassOfClass:[NSArray class]]) {
            return [(NSSet*)value allObjects];
        }
    } else if (orderedSetClass && [sourceType isSubclassOfClass:orderedSetClass]) {
        // OrderedSet -> Array
        if ([destinationType isSubclassOfClass:[NSArray class]]) {
            return [(NSOrderedSet*)value array];
        }
    } else if ([sourceType isSubclassOfClass:[NSArray class]]) {
        // Array -> Set
        if ([destinationType isSubclassOfClass:[NSSet class]]) {
            return [NSSet setWithArray:value];
        }
        // Array -> OrderedSet
        if (orderedSetClass && [destinationType isSubclassOfClass:orderedSetClass]) {
            return [orderedSetClass orderedSetWithArray:value];
        }
    } else if ([sourceType isSubclassOfClass:[NSNumber class]] && [destinationType isSubclassOfClass:[NSDate class]]) {
        // Number -> Date
        return [NSDate dateWithTimeIntervalSince1970:[(NSNumber*)value intValue]];
    } else if ([sourceType isSubclassOfClass:[NSNumber class]] && [destinationType isSubclassOfClass:[NSDecimalNumber class]]) {
        // Number -> Decimal Number
        return [NSDecimalNumber decimalNumberWithDecimal:[value decimalValue]];
    } else if ( ([sourceType isSubclassOfClass:NSClassFromString(@"__NSCFBoolean")] ||
                 [sourceType isSubclassOfClass:NSClassFromString(@"NSCFBoolean")] ) &&
               [destinationType isSubclassOfClass:[NSString class]]) {
        return ([value boolValue] ? @"true" : @"false");
    } else if ([destinationType isSubclassOfClass:[NSString class]] && [value respondsToSelector:@selector(stringValue)]) {
        return [value stringValue];
    } else if ([destinationType isSubclassOfClass:[NSString class]] && [value isKindOfClass:[NSDate class]]) {
        // NSDate -> NSString
        // Transform using the preferred date formatter
        NSString* dateString = nil;
        @synchronized(self.objectMapping.preferredDateFormatter) {
            dateString = [self.objectMapping.preferredDateFormatter stringFromDate:value];
        }
        return dateString;
    }

    RKLogWarning(@"Failed transformation of value at keyPath '%@'. No strategy for transforming from '%@' to '%@'", keyPath, NSStringFromClass([value class]), NSStringFromClass(destinationType));

    return nil;
}

- (BOOL)isValue:(id)sourceValue equalToValue:(id)destinationValue {
    return RKObjectIsValueEqualToValue(sourceValue, destinationValue);
}

- (BOOL)validateValue:(id)value atKeyPath:(NSString*)keyPath {
    BOOL success = YES;

	//NSLog(@"obj: %@", self.destinationObject);

    if (self.objectMapping.performKeyValueValidation && [self.destinationObject respondsToSelector:@selector(validateValue:forKey:error:)]) {
        success = [self.destinationObject validateValue:&value forKey:keyPath error:&_validationError];
        if (!success) {
            if (_validationError) {
                RKLogError(@"Validation failed while mapping attribute at key path %@ to value %@. Error: %@", keyPath, value, [_validationError localizedDescription]);
            } else {
                RKLogWarning(@"Destination object %@ rejected attribute value %@ for keyPath %@. Skipping...", self.destinationObject, value, keyPath);
            }
        }
    }

    return success;
}

- (BOOL)shouldSetValue:(id)value atKeyPath:(NSString*)keyPath
{
	id currentValue = [self.destinationObject valueForKeyPath:keyPath];
    if (currentValue == [NSNull null] || [currentValue isEqual:[NSNull null]]) {
        currentValue = nil;
    }

    /**
     WTF - This workaround should not be necessary, but I have been unable to replicate
     the circumstances that trigger it in a unit test to fix elsewhere. The proper place
     to handle it is in transformValue:atKeyPath:toType:

     See issue & pull request: https://github.com/RestKit/RestKit/pull/436
     */
    if (value == [NSNull null] || [value isEqual:[NSNull null]]) {
        RKLogWarning(@"Coercing NSNull value to nil in shouldSetValue:atKeyPath: -- should be fixed.");
        value = nil;
    }

	if (nil == currentValue && nil == value) {
		// Both are nil
        return NO;
	} else if (nil == value || nil == currentValue) {
		// One is nil and the other is not
        return [self validateValue:value atKeyPath:keyPath];
	}

    if (! [self isValue:value equalToValue:currentValue]) {
        // Validate value for key
        return [self validateValue:value atKeyPath:keyPath];
    }
    return NO;
}

- (NSArray*)applyNestingToMappings:(NSArray*)mappings {
    if (_nestedAttributeSubstitution) {
        NSString* searchString = [NSString stringWithFormat:@"(%@)", [[_nestedAttributeSubstitution allKeys] lastObject]];
        NSString* replacementString = [[_nestedAttributeSubstitution allValues] lastObject];
        NSMutableArray* array = [NSMutableArray arrayWithCapacity:[self.objectMapping.attributeMappings count]];
        for (RKObjectAttributeMapping* mapping in mappings) {
            RKObjectAttributeMapping* nestedMapping = [mapping copy];
            nestedMapping.sourceKeyPath = [nestedMapping.sourceKeyPath stringByReplacingOccurrencesOfString:searchString withString:replacementString];
            nestedMapping.destinationKeyPath = [nestedMapping.destinationKeyPath stringByReplacingOccurrencesOfString:searchString withString:replacementString];
            [array addObject:nestedMapping];
            [nestedMapping release];
        }

        return array;
    }

    return mappings;
}

- (NSArray*)attributeMappings {
    return [self applyNestingToMappings:self.objectMapping.attributeMappings];
}

- (NSArray*)relationshipMappings {
    return [self applyNestingToMappings:self.objectMapping.relationshipMappings];
}

- (void)applyAttributeMapping:(RKObjectAttributeMapping*)attributeMapping withValue:(id)value {
    if ([self.delegate respondsToSelector:@selector(objectMappingOperation:didFindMapping:forKeyPath:)]) {
        [self.delegate objectMappingOperation:self didFindMapping:attributeMapping forKeyPath:attributeMapping.sourceKeyPath];
    }
    RKLogTrace(@"Mapping attribute value keyPath '%@' to '%@'", attributeMapping.sourceKeyPath, attributeMapping.destinationKeyPath);

    // Inspect the property type to handle any value transformations
    Class type = [self.objectMapping classForProperty:attributeMapping.destinationKeyPath];
    if (type && NO == [[value class] isSubclassOfClass:type]) {
        value = [self transformValue:value atKeyPath:attributeMapping.sourceKeyPath toType:type];
    }

    // Ensure that the value is different
    if ([self shouldSetValue:value atKeyPath:attributeMapping.destinationKeyPath]) {
        RKLogTrace(@"Mapped attribute value from keyPath '%@' to '%@'. Value: %@", attributeMapping.sourceKeyPath, attributeMapping.destinationKeyPath, value);

        [self.destinationObject setValue:value forKey:attributeMapping.destinationKeyPath];
        if ([self.delegate respondsToSelector:@selector(objectMappingOperation:didSetValue:forKeyPath:usingMapping:)]) {
            [self.delegate objectMappingOperation:self didSetValue:value forKeyPath:attributeMapping.destinationKeyPath usingMapping:attributeMapping];
        }
    } else {
        RKLogTrace(@"Skipped mapping of attribute value from keyPath '%@ to keyPath '%@' -- value is unchanged (%@)", attributeMapping.sourceKeyPath, attributeMapping.destinationKeyPath, value);
    }
}

// Return YES if we mapped any attributes
- (BOOL)applyAttributeMappings {
    // If we have a nesting substitution value, we have alread
    BOOL appliedMappings = (_nestedAttributeSubstitution != nil);

    if (!self.objectMapping.performKeyValueValidation) {
        RKLogDebug(@"Key-value validation is disabled for mapping, skipping...");
    }

    for (RKObjectAttributeMapping* attributeMapping in [self attributeMappings]) {
        if ([attributeMapping isMappingForKeyOfNestedDictionary]) {
            RKLogTrace(@"Skipping attribute mapping for special keyPath '%@'", attributeMapping.sourceKeyPath);
            continue;
        }

        id value = nil;
        if ([attributeMapping.sourceKeyPath isEqualToString:@""]) {
            value = self.sourceObject;
        } else {
            value = [self.sourceObject valueForKeyPath:attributeMapping.sourceKeyPath];
        }
        if (value) {
            appliedMappings = YES;
            [self applyAttributeMapping:attributeMapping withValue:value];
        } else {
            if ([self.delegate respondsToSelector:@selector(objectMappingOperation:didNotFindMappingForKeyPath:)]) {
                [self.delegate objectMappingOperation:self didNotFindMappingForKeyPath:attributeMapping.sourceKeyPath];
            }
            RKLogTrace(@"Did not find mappable attribute value keyPath '%@'", attributeMapping.sourceKeyPath);

            // Optionally set the default value for missing values
            if ([self.objectMapping shouldSetDefaultValueForMissingAttributes]) {
                [self.destinationObject setValue:[self.objectMapping defaultValueForMissingAttribute:attributeMapping.destinationKeyPath]
                                          forKey:attributeMapping.destinationKeyPath];
                RKLogTrace(@"Setting nil for missing attribute value at keyPath '%@'", attributeMapping.sourceKeyPath);
            }
        }

        // Fail out if an error has occurred
        if (_validationError) {
            return NO;
        }
    }

    return appliedMappings;
}

- (BOOL)isValueACollection:(id)value {
    return ([value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSArray class]]);
}

- (BOOL)mapNestedObject:(id)anObject toObject:(id)anotherObject withRealtionshipMapping:(RKObjectRelationshipMapping*)relationshipMapping {
    NSAssert(anObject, @"Cannot map nested object without a nested source object");
    NSAssert(anotherObject, @"Cannot map nested object without a destination object");
    NSAssert(relationshipMapping, @"Cannot map a nested object relationship without a relationship mapping");
    NSError* error = nil;

    RKLogTrace(@"Performing nested object mapping using mapping %@ for data: %@", relationshipMapping, anObject);
    PCOManagedObjectMappingOperation* subOperation = [PCOManagedObjectMappingOperation mappingOperationFromObject:anObject toObject:anotherObject withMapping:relationshipMapping.mapping];
    subOperation.delegate = self.delegate;
    subOperation.queue = self.queue;
    if (NO == [subOperation performMapping:&error]) {
        RKLogWarning(@"WARNING: Failed mapping nested object: %@", [error localizedDescription]);
    }

    return YES;
}

- (BOOL)applyRelationshipMappings {
    BOOL appliedMappings = NO;
    id destinationObject = nil;

    for (RKObjectRelationshipMapping* relationshipMapping in [self relationshipMappings]) {
        id value = [self.sourceObject valueForKeyPath:relationshipMapping.sourceKeyPath];

        if (value == nil || value == [NSNull null] || [value isEqual:[NSNull null]]) {
            RKLogDebug(@"Did not find mappable relationship value keyPath '%@'", relationshipMapping.sourceKeyPath);

            // Optionally nil out the property
            if ([self.objectMapping setNilForMissingRelationships] && [self shouldSetValue:nil atKeyPath:relationshipMapping.destinationKeyPath]) {
                RKLogTrace(@"Setting nil for missing relationship value at keyPath '%@'", relationshipMapping.sourceKeyPath);
                [self.destinationObject setValue:nil forKey:relationshipMapping.destinationKeyPath];
            }

            continue;
        }

        // Handle case where incoming content is collection represented by a dictionary
        if (relationshipMapping.mapping.forceCollectionMapping) {
            // If we have forced mapping of a dictionary, map each subdictionary
            if ([value isKindOfClass:[NSDictionary class]]) {
                RKLogDebug(@"Collection mapping forced for NSDictionary, mapping each key/value independently...");
                NSArray* objectsToMap = [NSMutableArray arrayWithCapacity:[value count]];
                for (id key in value) {
                    NSDictionary* dictionaryToMap = [NSDictionary dictionaryWithObject:[value valueForKey:key] forKey:key];
                    [(NSMutableArray*)objectsToMap addObject:dictionaryToMap];
                }
                value = objectsToMap;
            } else {
                RKLogWarning(@"Collection mapping forced but mappable objects is of type '%@' rather than NSDictionary", NSStringFromClass([value class]));
            }
        }

        // Handle case where incoming content is a single object, but we want a collection
        Class relationshipType = [self.objectMapping classForProperty:relationshipMapping.destinationKeyPath];
        BOOL mappingToCollection = (relationshipType &&
                                    ([relationshipType isSubclassOfClass:[NSSet class]] || [relationshipType isSubclassOfClass:[NSArray class]]));
        if (mappingToCollection && ![self isValueACollection:value]) {
            RKLogDebug(@"Asked to map a single object into a collection relationship. Transforming to an instance of: %@", NSStringFromClass(relationshipType));
            if ([relationshipType isSubclassOfClass:[NSArray class]]) {
                value = [relationshipType arrayWithObject:value];
            } else if ([relationshipType isSubclassOfClass:[NSSet class]]) {
                value = [relationshipType setWithObject:value];
            } else {
                RKLogWarning(@"Failed to transform single object");
            }
        }

        if ([self isValueACollection:value])
		{
			// One to many relationship
            RKLogDebug(@"Mapping one to many relationship value at keyPath '%@' to '%@'", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath);
            appliedMappings = YES;

            destinationObject = [NSMutableArray arrayWithCapacity:[value count]];
            id collectionSanityCheckObject = nil;
            if ([value respondsToSelector:@selector(anyObject)]) collectionSanityCheckObject = [value anyObject];
            if ([value respondsToSelector:@selector(lastObject)]) collectionSanityCheckObject = [value lastObject];
            if ([self isValueACollection:collectionSanityCheckObject]) {
                RKLogWarning(@"WARNING: Detected a relationship mapping for a collection containing another collection. This is probably not what you want. Consider using a KVC collection operator (such as @unionOfArrays) to flatten your mappable collection.");
                RKLogWarning(@"Key path '%@' yielded collection containing another collection rather than a collection of objects: %@", relationshipMapping.sourceKeyPath, value);
            }
            for (id nestedObject in value) {
                id<RKObjectMappingDefinition> mapping = relationshipMapping.mapping;
                PCOManagedObjectMapping* objectMapping = nil;
                if ([mapping isKindOfClass:[RKDynamicObjectMapping class]]) {
                    objectMapping = [(RKDynamicObjectMapping*)mapping objectMappingForDictionary:nestedObject];
                    if (! objectMapping) {
                        RKLogDebug(@"Mapping %@ declined mapping for data %@: returned nil objectMapping", mapping, nestedObject);
                        continue;
                    }
                } else if ([mapping isKindOfClass:[PCOManagedObjectMapping class]]) {
                    objectMapping = (PCOManagedObjectMapping*)mapping;
                } else {
                    NSAssert(objectMapping, @"Encountered unknown mapping type '%@'", NSStringFromClass([mapping class]));
                }
                id mappedObject = [objectMapping mappableObjectForData:nestedObject inContext:_backgroundManagedObjectContext];
                if ([self mapNestedObject:nestedObject toObject:mappedObject withRealtionshipMapping:relationshipMapping]) {
                    [destinationObject addObject:mappedObject];
                }
            }

            // Transform from NSSet <-> NSArray if necessary
            Class type = [self.objectMapping classForProperty:relationshipMapping.destinationKeyPath];
            if (type && NO == [[destinationObject class] isSubclassOfClass:type]) {
                destinationObject = [self transformValue:destinationObject atKeyPath:relationshipMapping.sourceKeyPath toType:type];
            }

            // If the relationship has changed, set it
            if ([self shouldSetValue:destinationObject atKeyPath:relationshipMapping.destinationKeyPath]) {
                Class managedObjectClass = NSClassFromString(@"NSManagedObject");
                if (managedObjectClass && [self.destinationObject isKindOfClass:managedObjectClass]) {
                    RKLogTrace(@"Found a managedObject collection. About to apply value via mutable[Set|Array]ValueForKey");
                    if ([destinationObject isKindOfClass:[NSSet class]]) {
                        RKLogTrace(@"Mapped NSSet relationship object from keyPath '%@' to '%@'. Value: %@", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath, destinationObject);
                        NSMutableSet* destinationSet = [self.destinationObject mutableSetValueForKey:relationshipMapping.destinationKeyPath];
                        [destinationSet setSet:destinationObject];
                    } else if ([destinationObject isKindOfClass:[NSArray class]]) {
                        RKLogTrace(@"Mapped NSArray relationship object from keyPath '%@' to '%@'. Value: %@", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath, destinationObject);
                        NSMutableArray* destinationArray = [self.destinationObject mutableArrayValueForKey:relationshipMapping.destinationKeyPath];
                        [destinationArray setArray:destinationObject];
                    }
                } else {
                    RKLogTrace(@"Mapped relationship object from keyPath '%@' to '%@'. Value: %@", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath, destinationObject);
                    [self.destinationObject setValue:destinationObject forKey:relationshipMapping.destinationKeyPath];
                }
            }
        }
		else
		{
            // One to one relationship
            RKLogDebug(@"Mapping one to one relationship value at keyPath '%@' to '%@'", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath);

            id<RKObjectMappingDefinition> mapping = relationshipMapping.mapping;
            PCOManagedObjectMapping* objectMapping = nil;
            if ([mapping isKindOfClass:[RKDynamicObjectMapping class]]) {
                objectMapping = [(RKDynamicObjectMapping*)mapping objectMappingForDictionary:value];
            } else if ([mapping isKindOfClass:[PCOManagedObjectMapping class]]) {
                objectMapping = (PCOManagedObjectMapping*)mapping;
            }
            NSAssert(objectMapping, @"Encountered unknown mapping type '%@'", NSStringFromClass([mapping class]));
            destinationObject = [objectMapping mappableObjectForData:value inContext:_backgroundManagedObjectContext];
            if ([self mapNestedObject:value toObject:destinationObject withRealtionshipMapping:relationshipMapping]) {
                appliedMappings = YES;
            }
        }

        // If the relationship has changed, set it
        if ([self shouldSetValue:destinationObject atKeyPath:relationshipMapping.destinationKeyPath]) {
            RKLogTrace(@"Mapped relationship object from keyPath '%@' to '%@'. Value: %@", relationshipMapping.sourceKeyPath, relationshipMapping.destinationKeyPath, destinationObject);
            [self.destinationObject setValue:destinationObject forKey:relationshipMapping.destinationKeyPath];
        }

        // Fail out if a validation error has occurred
        if (_validationError) {
            return NO;
        }
    }

    return appliedMappings;
}

- (void)applyNestedMappings {
    RKObjectAttributeMapping* attributeMapping = [self.objectMapping attributeMappingForKeyOfNestedDictionary];
    if (attributeMapping) {
        RKLogDebug(@"Found nested mapping definition to attribute '%@'", attributeMapping.destinationKeyPath);
        id attributeValue = [[self.sourceObject allKeys] lastObject];
        if (attributeValue) {
            RKLogDebug(@"Found nesting value of '%@' for attribute '%@'", attributeValue, attributeMapping.destinationKeyPath);
            _nestedAttributeSubstitution = [[NSDictionary alloc] initWithObjectsAndKeys:attributeValue, attributeMapping.destinationKeyPath, nil];
            [self applyAttributeMapping:attributeMapping withValue:attributeValue];
        } else {
            RKLogWarning(@"Unable to find nesting value for attribute '%@'", attributeMapping.destinationKeyPath);
        }
    }
}






// TODO: Move this to a better home to take exposure out of the mapper
- (Class)operationClassForMapping:(PCOManagedObjectMapping *)mapping {
    Class managedMappingClass = NSClassFromString(@"PCOManagedObjectMapping");
    Class managedMappingOperationClass = NSClassFromString(@"PCOManagedObjectMappingOperation");
    if (managedMappingClass != nil && [mapping isMemberOfClass:managedMappingClass]) {
        return managedMappingOperationClass;
    }
	
    return [PCOManagedObjectMappingOperation class];
}

- (void)connectRelationship:(NSString *)relationshipName {
    NSDictionary* relationshipsAndPrimaryKeyAttributes = [(PCOManagedObjectMapping*)self.objectMapping relationshipsAndPrimaryKeyAttributes];
    NSString* primaryKeyAttribute = [relationshipsAndPrimaryKeyAttributes objectForKey:relationshipName];
    RKObjectRelationshipMapping* relationshipMapping = [self.objectMapping mappingForRelationship:relationshipName];
    id<RKObjectMappingDefinition> mapping = relationshipMapping.mapping;
    //NSAssert(mapping, @"Attempted to connect relationship for keyPath '%@' without a relationship mapping defined.");
    if (! [mapping isKindOfClass:[PCOManagedObjectMapping class]]) {
        RKLogWarning(@"Can only connect relationships for PCOManagedObjectMapping relationships. Found %@: Skipping...", NSStringFromClass([mapping class]));
        return;
    }
    PCOManagedObjectMapping* objectMapping = (PCOManagedObjectMapping*)mapping;
    NSAssert(relationshipMapping, @"Unable to find relationship mapping '%@' to connect by primaryKey", relationshipName);
    NSAssert([relationshipMapping isKindOfClass:[RKObjectRelationshipMapping class]], @"Expected mapping for %@ to be a relationship mapping", relationshipName);
    NSAssert([relationshipMapping.mapping isKindOfClass:[PCOManagedObjectMapping class]], @"Can only connect PCOManagedObjectMapping relationships");
    NSString* primaryKeyAttributeOfRelatedObject = [(PCOManagedObjectMapping*)objectMapping primaryKeyAttribute];
    NSAssert(primaryKeyAttributeOfRelatedObject, @"Cannot connect relationship: mapping for %@ has no primary key attribute specified", NSStringFromClass(objectMapping.objectClass));
    id valueOfLocalPrimaryKeyAttribute = [self.destinationObject valueForKey:primaryKeyAttribute];
    RKLogDebug(@"Connecting relationship at keyPath '%@' to object with primaryKey attribute '%@'", relationshipName, primaryKeyAttributeOfRelatedObject);
    if (valueOfLocalPrimaryKeyAttribute) {
        id relatedObject = [objectMapping.objectClass findFirstByAttribute:primaryKeyAttributeOfRelatedObject withValue:valueOfLocalPrimaryKeyAttribute inContext:_backgroundManagedObjectContext];
        if (relatedObject) {
            RKLogTrace(@"Connected relationship '%@' to object with primary key value '%@': %@", relationshipName, valueOfLocalPrimaryKeyAttribute, relatedObject);
        } else {
            RKLogTrace(@"Failed to find object to connect relationship '%@' with primary key value '%@'", relationshipName, valueOfLocalPrimaryKeyAttribute);
        }
        [self.destinationObject setValue:relatedObject forKey:relationshipName];
    } else {
        RKLogTrace(@"Failed to find primary key value for attribute '%@'", primaryKeyAttribute);
    }
}

- (void)connectRelationships {
    if ([self.objectMapping isKindOfClass:[PCOManagedObjectMapping class]]) {
        NSDictionary* relationshipsAndPrimaryKeyAttributes = [(PCOManagedObjectMapping*)self.objectMapping relationshipsAndPrimaryKeyAttributes];
        for (NSString* relationshipName in relationshipsAndPrimaryKeyAttributes) {
            if (self.queue) {
                RKLogTrace(@"Enqueueing relationship connection using operation queue");
                [self.queue addOperationWithBlock:^{
                    [self connectRelationship:relationshipName];
                }];
            } else {
                [self connectRelationship:relationshipName];
            }
        }
    }
}

- (BOOL)performMapping:(NSError **)error
{
	_backgroundManagedObjectContext = [[[RKObjectManager sharedManager] objectStore] newManagedObjectContext];

	BOOL success = YES;

	RKLogDebug(@"Starting mapping operation...");
    RKLogTrace(@"Performing mapping operation: %@", self);

	
    [self applyNestedMappings];
    BOOL mappedAttributes = [self applyAttributeMappings];
    BOOL mappedRelationships = [self applyRelationshipMappings];
    if ((mappedAttributes || mappedRelationships) && _validationError == nil) {
        RKLogDebug(@"Finished mapping operation successfully...");
        success = YES;
    }

	[_backgroundManagedObjectContext save:error];

    if (_validationError) {
        // We failed out due to validation
        if (error) *error = _validationError;
        if ([self.delegate respondsToSelector:@selector(objectMappingOperation:didFailWithError:)]) {
            [self.delegate objectMappingOperation:self didFailWithError:_validationError];
        }

		success = NO;

        RKLogError(@"Failed mapping operation: %@", [_validationError localizedDescription]);
    } else {
        // We did not find anything to do
        RKLogDebug(@"Mapping operation did not find any mappable content");

		success = NO;
    }
	
    [self connectRelationships];
	 

	[_backgroundManagedObjectContext save:error];

	[_backgroundManagedObjectContext release], _backgroundManagedObjectContext = nil;

    return success;
}


@end
