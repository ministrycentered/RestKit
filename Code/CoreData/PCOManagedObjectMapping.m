//
//  PCOManagedObjectMapping.m
//  RestKit
//
//  Created by Jason on 8/18/12.
//  Copyright (c) 2012 RestKit. All rights reserved.
//

#import "PCOManagedObjectMapping.h"

#import "RKObjectManager.h"
#import "RKManagedObjectStore.h"

#import "RKObjectRelationshipMapping.h"

#import "RKObjectPropertyInspector.h"
#import "RKObjectPropertyInspector+CoreData.h"

#import "RKLog.h"

// Constants
NSString* const RKObjectMappingNestingAttributeKeyName = @"<RK_NESTING_ATTRIBUTE>";


@implementation PCOManagedObjectMapping

+ (id)mappingForClass:(Class)objectClass {
    PCOManagedObjectMapping* mapping = [self new];
    mapping.objectClass = objectClass;
    return [mapping autorelease];
}

+ (id)serializationMapping {
    return [self mappingForClass:[NSMutableDictionary class]];
}

#if NS_BLOCKS_AVAILABLE

+ (id)mappingForClass:(Class)objectClass block:(void(^)(PCOManagedObjectMapping*))block {
    PCOManagedObjectMapping* mapping = [self mappingForClass:objectClass];
    block(mapping);
    return mapping;
}

+ (id)serializationMappingWithBlock:(void(^)(PCOManagedObjectMapping*))block {
    PCOManagedObjectMapping* mapping = [self serializationMapping];
    block(mapping);
    return mapping;
}

#endif // NS_BLOCKS_AVAILABLE

- (id)init {
    self = [super init];
    if (self) {
        _mappings = [NSMutableArray new];
        self.setDefaultValueForMissingAttributes = NO;
        self.setNilForMissingRelationships = NO;
        self.forceCollectionMapping = NO;
        self.performKeyValueValidation = YES;

		_relationshipToPrimaryKeyMappings = [[NSMutableDictionary alloc] init];
    }

    return self;
}

- (void)dealloc
{
	[_managedObjectContext release];
    [_entity release];
    [_relationshipToPrimaryKeyMappings release];

    [_rootKeyPath release];
    [_mappings release];
    [_dateFormatters release];
    [_preferredDateFormatter release];
    [super dealloc];
}

- (NSArray*)mappedKeyPaths {
    return [_mappings valueForKey:@"destinationKeyPath"];
}

- (NSArray*)attributeMappings {
    NSMutableArray* mappings = [NSMutableArray array];
    for (RKObjectAttributeMapping* mapping in self.mappings) {
        if ([mapping isMemberOfClass:[RKObjectAttributeMapping class]]) {
            [mappings addObject:mapping];
        }
    }

    return mappings;
}

- (NSArray*)relationshipMappings {
    NSMutableArray* mappings = [NSMutableArray array];
    for (RKObjectAttributeMapping* mapping in self.mappings) {
        if ([mapping isMemberOfClass:[RKObjectRelationshipMapping class]]) {
            [mappings addObject:mapping];
        }
    }

    return mappings;
}

- (void)addAttributeMapping:(RKObjectAttributeMapping*)mapping {
    NSAssert1([[self mappedKeyPaths] containsObject:mapping.destinationKeyPath] == NO, @"Unable to add mapping for keyPath %@, one already exists...", mapping.destinationKeyPath);
    [_mappings addObject:mapping];
}

- (void)addRelationshipMapping:(RKObjectRelationshipMapping*)mapping {
    [self addAttributeMapping:mapping];
}

- (NSString*)description {
    return [NSString stringWithFormat:@"PCOManagedObjectMapping class => %@: keyPath mappings => %@", NSStringFromClass(self.objectClass), _mappings];
}

- (id)mappingForKeyPath:(NSString*)keyPath {
    for (RKObjectAttributeMapping* mapping in _mappings) {
        if ([mapping.sourceKeyPath isEqualToString:keyPath]) {
            return mapping;
        }
    }

    return nil;
}

- (void)mapAttributesCollection:(id<NSFastEnumeration>)attributes {
    for (NSString* attributeKeyPath in attributes) {
        [self addAttributeMapping:[RKObjectAttributeMapping mappingFromKeyPath:attributeKeyPath toKeyPath:attributeKeyPath]];
    }
}

- (void)mapAttributes:(NSString*)attributeKeyPath, ... {
    va_list args;
    va_start(args, attributeKeyPath);
	NSMutableSet* attributeKeyPaths = [NSMutableSet set];

    for (NSString* keyPath = attributeKeyPath; keyPath != nil; keyPath = va_arg(args, NSString*)) {
        [attributeKeyPaths addObject:keyPath];
    }

    va_end(args);

    [self mapAttributesCollection:attributeKeyPaths];
}

- (void)mapAttributesFromSet:(NSSet *)set {
    [self mapAttributesCollection:set];
}

- (void)mapAttributesFromArray:(NSArray *)array {
    [self mapAttributesCollection:[NSSet setWithArray:array]];
}

- (void)mapKeyPath:(NSString *)relationshipKeyPath toRelationship:(NSString*)keyPath withMapping:(id<RKObjectMappingDefinition>)objectOrDynamicMapping serialize:(BOOL)serialize {
    RKObjectRelationshipMapping* mapping = [RKObjectRelationshipMapping mappingFromKeyPath:relationshipKeyPath toKeyPath:keyPath withMapping:objectOrDynamicMapping reversible:serialize];
    [self addRelationshipMapping:mapping];
}

- (void)mapKeyPath:(NSString *)relationshipKeyPath toRelationship:(NSString*)keyPath withMapping:(id<RKObjectMappingDefinition>)objectOrDynamicMapping {
    [self mapKeyPath:relationshipKeyPath toRelationship:keyPath withMapping:objectOrDynamicMapping serialize:YES];
}

- (void)mapRelationship:(NSString*)relationshipKeyPath withMapping:(id<RKObjectMappingDefinition>)objectOrDynamicMapping {
    [self mapKeyPath:relationshipKeyPath toRelationship:relationshipKeyPath withMapping:objectOrDynamicMapping];
}

- (void)mapKeyPath:(NSString*)sourceKeyPath toAttribute:(NSString*)destinationKeyPath {
    RKObjectAttributeMapping* mapping = [RKObjectAttributeMapping mappingFromKeyPath:sourceKeyPath toKeyPath:destinationKeyPath];
    [self addAttributeMapping:mapping];
}

- (void)hasMany:(NSString*)keyPath withMapping:(id<RKObjectMappingDefinition>)objectOrDynamicMapping {
    [self mapRelationship:keyPath withMapping:objectOrDynamicMapping];
}

- (void)hasOne:(NSString*)keyPath withMapping:(id<RKObjectMappingDefinition>)objectOrDynamicMapping {
    [self mapRelationship:keyPath withMapping:objectOrDynamicMapping];
}

- (void)removeAllMappings {
    [_mappings removeAllObjects];
}

- (void)removeMapping:(RKObjectAttributeMapping*)attributeOrRelationshipMapping {
    [_mappings removeObject:attributeOrRelationshipMapping];
}

- (void)removeMappingForKeyPath:(NSString*)keyPath {
    RKObjectAttributeMapping* mapping = [self mappingForKeyPath:keyPath];
    [self removeMapping:mapping];
}

#ifndef MAX_INVERSE_MAPPING_RECURSION_DEPTH
#define MAX_INVERSE_MAPPING_RECURSION_DEPTH (100)
#endif
- (PCOManagedObjectMapping*)inverseMappingAtDepth:(NSInteger)depth {
    NSAssert(depth < MAX_INVERSE_MAPPING_RECURSION_DEPTH, @"Exceeded max recursion level in inverseMapping. This is likely due to a loop in the serialization graph. To break this loop, specify one-way relationships by setting serialize to NO in mapKeyPath:toRelationship:withObjectMapping:serialize:");
    PCOManagedObjectMapping* inverseMapping = [PCOManagedObjectMapping mappingForClass:[NSMutableDictionary class]];
    for (RKObjectAttributeMapping* attributeMapping in self.attributeMappings) {
        [inverseMapping mapKeyPath:attributeMapping.destinationKeyPath toAttribute:attributeMapping.sourceKeyPath];
    }

    for (RKObjectRelationshipMapping* relationshipMapping in self.relationshipMappings) {
        if (relationshipMapping.reversible) {
            id<RKObjectMappingDefinition> mapping = relationshipMapping.mapping;
            if (! [mapping isKindOfClass:[PCOManagedObjectMapping class]]) {
                RKLogWarning(@"Unable to generate inverse mapping for relationship '%@': %@ relationships cannot be inversed.", relationshipMapping.sourceKeyPath, NSStringFromClass([mapping class]));
                continue;
            }
            [inverseMapping mapKeyPath:relationshipMapping.destinationKeyPath toRelationship:relationshipMapping.sourceKeyPath withMapping:[(PCOManagedObjectMapping*)mapping inverseMappingAtDepth:depth+1]];
        }
    }

    return inverseMapping;
}

- (PCOManagedObjectMapping*)inverseMapping {
    return [self inverseMappingAtDepth:0];
}

- (void)mapKeyPathsToAttributes:(NSString*)firstKeyPath, ... {
    va_list args;
    va_start(args, firstKeyPath);
    for (NSString* keyPath = firstKeyPath; keyPath != nil; keyPath = va_arg(args, NSString*)) {
		NSString* attributeKeyPath = va_arg(args, NSString*);
        NSAssert(attributeKeyPath != nil, @"Cannot map a keyPath without a destination attribute keyPath");
        [self mapKeyPath:keyPath toAttribute:attributeKeyPath];
        // TODO: Raise proper exception here, argument error...
    }
    va_end(args);
}

- (void)mapKeyOfNestedDictionaryToAttribute:(NSString*)attributeName {
    [self mapKeyPath:RKObjectMappingNestingAttributeKeyName toAttribute:attributeName];
}

- (RKObjectAttributeMapping *)attributeMappingForKeyOfNestedDictionary {
    return [self mappingForKeyPath:RKObjectMappingNestingAttributeKeyName];
}

- (RKObjectAttributeMapping*)mappingForAttribute:(NSString*)attributeKey {
    for (RKObjectAttributeMapping* mapping in [self attributeMappings]) {
        if ([mapping.destinationKeyPath isEqualToString:attributeKey]) {
            return mapping;
        }
    }

    return nil;
}

- (RKObjectRelationshipMapping*)mappingForRelationship:(NSString*)relationshipKey {
    for (RKObjectRelationshipMapping* mapping in [self relationshipMappings]) {
        if ([mapping.destinationKeyPath isEqualToString:relationshipKey]) {
            return mapping;
        }
    }

    return nil;
}

- (id)defaultValueForMissingAttribute:(NSString*)attributeName {
    NSAttributeDescription *desc = [[self.entity attributesByName] valueForKey:attributeName];
    return [desc defaultValue];
}


- (id)mappableObjectForData:(id)mappableData {
	NSAssert(1 == 0, @"Nope.");

    return [[self.objectClass new] autorelease];
}


- (Class)classForProperty:(NSString*)propertyName {
    Class propertyClass = [[RKObjectPropertyInspector sharedInspector] typeForProperty:propertyName ofClass:self.objectClass];
    if (! propertyClass) {
        propertyClass = [[RKObjectPropertyInspector sharedInspector] typeForProperty:propertyName ofEntity:self.entity];
    }

    return propertyClass;
}

#pragma mark - Date and Time

- (NSDateFormatter *)preferredDateFormatter {
    return _preferredDateFormatter ? _preferredDateFormatter : [PCOManagedObjectMapping preferredDateFormatter];
}

- (NSArray *)dateFormatters {
    return _dateFormatters ? _dateFormatters : [PCOManagedObjectMapping defaultDateFormatters];
}





+ (id)mappingForClass:(Class)objectClass inContext:(NSManagedObjectContext *)context {
    return [self mappingForEntityWithName:NSStringFromClass(objectClass) inManagedObjectContext:context];
}

+ (PCOManagedObjectMapping*)mappingForEntity:(NSEntityDescription*)entity inManagedObjectContext:(NSManagedObjectContext *)moc {
    return [[[self alloc] initWithEntity:entity inManagedObjectContext:moc] autorelease];
}

+ (PCOManagedObjectMapping*)mappingForEntityWithName:(NSString*)entityName inManagedObjectContext:(NSManagedObjectContext *)moc {
    return [self mappingForEntity:[NSEntityDescription entityForName:entityName inManagedObjectContext:moc] inManagedObjectContext:moc];
}

- (id)initWithEntity:(NSEntityDescription*)entity inManagedObjectContext:(NSManagedObjectContext *)moc {
    NSAssert(entity, @"Cannot initialize an PCOManagedObjectMapping without an entity. Maybe you want PCOManagedObjectMapping instead?");
    self = [self init];
    if (self) {
        self.objectClass = NSClassFromString([entity managedObjectClassName]);
        _entity = [entity retain];
		_managedObjectContext = [moc retain];
    }

    return self;
}


- (NSDictionary*)relationshipsAndPrimaryKeyAttributes {
    return _relationshipToPrimaryKeyMappings;
}

- (void)connectRelationship:(NSString*)relationshipName withObjectForPrimaryKeyAttribute:(NSString*)primaryKeyAttribute {
    NSAssert([_relationshipToPrimaryKeyMappings objectForKey:relationshipName] == nil, @"Cannot add connect relationship %@ by primary key, a mapping already exists.", relationshipName);
    [_relationshipToPrimaryKeyMappings setObject:primaryKeyAttribute forKey:relationshipName];
}

- (void)connectRelationshipsWithObjectsForPrimaryKeyAttributes:(NSString*)firstRelationshipName, ... {
    va_list args;
    va_start(args, firstRelationshipName);
    for (NSString* relationshipName = firstRelationshipName; relationshipName != nil; relationshipName = va_arg(args, NSString*)) {
		NSString* primaryKeyAttribute = va_arg(args, NSString*);
        NSAssert(primaryKeyAttribute != nil, @"Cannot connect a relationship without an attribute containing the primary key");
        [self connectRelationship:relationshipName withObjectForPrimaryKeyAttribute:primaryKeyAttribute];
        // TODO: Raise proper exception here, argument error...
    }
    va_end(args);
}



- (id)mappableObjectForData:(id)mappableData inContext:(NSManagedObjectContext *)context
{
    //NSAssert(mappableData, @"Mappable data cannot be nil");

	if (mappableData == nil)
	{
		return nil;
	}

    // TODO: We do not want to be using this singleton reference to the object store.
    // Clean this up when we update the Core Data internals
    RKManagedObjectStore* objectStore = [RKObjectManager sharedManager].objectStore;

	if (objectStore == nil)
	{
		return nil;
	}

    id object = nil;
    id primaryKeyValue = nil;
    NSString* primaryKeyAttribute;

    NSEntityDescription* entity = [self entity];
    RKObjectAttributeMapping* primaryKeyAttributeMapping = nil;

    primaryKeyAttribute = [self primaryKeyAttribute];
    if (primaryKeyAttribute) {
        // If a primary key has been set on the object mapping, find the attribute mapping
        // so that we can extract any existing primary key from the mappable data
        for (RKObjectAttributeMapping* attributeMapping in self.attributeMappings) {
            if ([attributeMapping.destinationKeyPath isEqualToString:primaryKeyAttribute]) {
                primaryKeyAttributeMapping = attributeMapping;
                break;
            }
        }

        // Get the primary key value out of the mappable data (if any)
        if ([primaryKeyAttributeMapping isMappingForKeyOfNestedDictionary]) {
            RKLogDebug(@"Detected use of nested dictionary key as primaryKey attribute...");
            primaryKeyValue = [[mappableData allKeys] lastObject];
        } else {
            NSString* keyPathForPrimaryKeyElement = primaryKeyAttributeMapping.sourceKeyPath;
            if (keyPathForPrimaryKeyElement) {
                primaryKeyValue = [mappableData valueForKeyPath:keyPathForPrimaryKeyElement];
            }
        }
    }

    // If we have found the primary key attribute & value, try to find an existing instance to update
    if (primaryKeyAttribute && primaryKeyValue) {
        object = [objectStore findOrCreateInstanceOfEntity:entity inManagedObjectContext:context withPrimaryKeyAttribute:primaryKeyAttribute andValue:primaryKeyValue];
        //NSAssert2(object, @"Failed creation of managed object with entity '%@' and primary key value '%@'", entity.name, primaryKeyValue);
    } else {
        object = [[[NSManagedObject alloc] initWithEntity:entity
                           insertIntoManagedObjectContext:context] autorelease];
    }

    return object;
}





@end

/////////////////////////////////////////////////////////////////////////////

static NSMutableArray *defaultDateFormatters = nil;
static NSDateFormatter *preferredDateFormatter = nil;

@implementation PCOManagedObjectMapping (DateAndTimeFormatting)

+ (NSArray *)defaultDateFormatters {
    if (!defaultDateFormatters) {
        defaultDateFormatters = [[NSMutableArray alloc] initWithCapacity:2];

        // Setup the default formatters
        [self addDefaultDateFormatterForString:@"yyyy-MM-dd'T'HH:mm:ss'Z'" inTimeZone:nil];
        [self addDefaultDateFormatterForString:@"MM/dd/yyyy" inTimeZone:nil];
    }

    return defaultDateFormatters;
}

+ (void)setDefaultDateFormatters:(NSArray *)dateFormatters {
    [defaultDateFormatters release];
    defaultDateFormatters = nil;
    if (dateFormatters) {
        defaultDateFormatters = [[NSMutableArray alloc] initWithArray:dateFormatters];
    }
}


+ (void)addDefaultDateFormatter:(NSDateFormatter *)dateFormatter {
    [self defaultDateFormatters];
    [defaultDateFormatters addObject:dateFormatter];
}

+ (void)addDefaultDateFormatterForString:(NSString *)dateFormatString inTimeZone:(NSTimeZone *)nilOrTimeZone {
    NSDateFormatter *dateFormatter = [[[NSDateFormatter alloc] init] autorelease];
    dateFormatter.dateFormat = dateFormatString;
    dateFormatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    if (nilOrTimeZone) {
        dateFormatter.timeZone = nilOrTimeZone;
    } else {
        dateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    }

    [self addDefaultDateFormatter:dateFormatter];
    [dateFormatter release];

}

+ (NSDateFormatter *)preferredDateFormatter {
    if (!preferredDateFormatter) {
        // A date formatter that matches the output of [NSDate description]
        preferredDateFormatter = [NSDateFormatter new];
        [preferredDateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss Z"];
        preferredDateFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        preferredDateFormatter.locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease];
    }

    return preferredDateFormatter;
}

+ (void)setPreferredDateFormatter:(NSDateFormatter *)dateFormatter {
    [dateFormatter retain];
    [preferredDateFormatter release];
    preferredDateFormatter = dateFormatter;
}

@end
