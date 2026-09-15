/*
 * rdp-retina – Kennwörter im Schlüsselbund
 */
#import "RRCredentials.h"

#import <Security/Security.h>

static NSString *const RRCredentialsService = @"rdp-retina";

NSString *RRCredentialsAccount(rdpSettings *settings)
{
	const char *user = freerdp_settings_get_string(settings, FreeRDP_Username);
	const char *host = freerdp_settings_get_string(settings, FreeRDP_ServerHostname);
	const char *domain = freerdp_settings_get_string(settings, FreeRDP_Domain);
	const UINT32 port = freerdp_settings_get_uint32(settings, FreeRDP_ServerPort);
	/* %s in NSString-Formaten liest nicht als UTF-8, daher über NSString. */
	NSString *userText = user ? [NSString stringWithUTF8String:user] : nil;
	NSString *hostText = host ? [NSString stringWithUTF8String:host] : nil;
	NSString *domainText = domain ? [NSString stringWithUTF8String:domain] : nil;

	if ((userText.length == 0) || (hostText.length == 0))
		return nil;

	NSMutableString *account = [NSMutableString new];
	if (domainText.length > 0)
		[account appendFormat:@"%@\\", domainText];
	[account appendFormat:@"%@@%@", userText, hostText];
	if ((port != 0) && (port != 3389))
		[account appendFormat:@":%u", (unsigned)port];
	return account.lowercaseString;
}

static NSMutableDictionary *RRCredentialsQuery(NSString *account)
{
	return [@{
		(__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService : RRCredentialsService,
		(__bridge id)kSecAttrAccount : account,
	} mutableCopy];
}

static NSError *RRCredentialsError(OSStatus status)
{
	NSString *text = (__bridge_transfer NSString *)SecCopyErrorMessageString(status, NULL);
	NSDictionary *info = text ? @{ NSLocalizedDescriptionKey : text } : nil;
	return [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:info];
}

BOOL RRCredentialsStore(NSString *account, NSString *password, NSError **error)
{
	NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableDictionary *query = RRCredentialsQuery(account);

	if (!data)
		return NO;

	OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
	if (status == errSecSuccess)
	{
		NSDictionary *update = @{ (__bridge id)kSecValueData : data };
		status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)update);
	}
	else if (status == errSecItemNotFound)
	{
		query[(__bridge id)kSecValueData] = data;
		query[(__bridge id)kSecAttrLabel] = [NSString stringWithFormat:@"rdp-retina: %@", account];
		query[(__bridge id)kSecAttrDescription] = @"RDP-Kennwort";
		status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
	}

	if (status != errSecSuccess)
	{
		if (error)
			*error = RRCredentialsError(status);
		return NO;
	}
	return YES;
}

BOOL RRCredentialsApply(rdpSettings *settings)
{
	const char *password = freerdp_settings_get_string(settings, FreeRDP_Password);

	if (password && (*password != '\0'))
		return NO;

	NSString *account = RRCredentialsAccount(settings);
	if (!account)
		return NO;

	NSMutableDictionary *query = RRCredentialsQuery(account);
	query[(__bridge id)kSecReturnData] = @YES;
	query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;

	CFTypeRef found = NULL;
	if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &found) != errSecSuccess)
		return NO;

	NSData *data = (__bridge_transfer NSData *)found;
	NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
	if (text.length == 0)
		return NO;

	return freerdp_settings_set_string(settings, FreeRDP_Password, text.UTF8String) ? YES : NO;
}
