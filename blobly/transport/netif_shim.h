// C helpers for netif.v: the host's network interfaces, and a multicast join on one of them by
// index. Kept in C for the reason udp_reuseport_shim.h is: getifaddrs / GetAdaptersAddresses and
// struct group_req are plain C structs, easier to get right here than in V's view of them.
#ifndef BLOBLY_NETIF_SHIM_H
#define BLOBLY_NETIF_SHIM_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>
#else
#include <errno.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <netdb.h>
#endif

#ifdef __linux__
#ifdef IP_MULTICAST_ALL
#define CT_IP_MULTICAST_ALL IP_MULTICAST_ALL
#else
#define CT_IP_MULTICAST_ALL 49
#endif
#ifdef IPV6_MULTICAST_ALL
#define CT_IPV6_MULTICAST_ALL IPV6_MULTICAST_ALL
#else
#define CT_IPV6_MULTICAST_ALL 29
#endif
#endif

#ifndef NI_MAXHOST
#define NI_MAXHOST 1025
#endif

// ct_netif_put appends `s` to buf when it fits, and counts it either way.
static void ct_netif_put(char *buf, int cap, int *n, const char *s) {
	int l = (int)strlen(s);
	if (*n + l <= cap) memcpy(buf + *n, s, (size_t)l);
	*n += l;
}

// ct_netif_addr writes a socket address's numeric text into host ('' for any other family).
static void ct_netif_addr(const struct sockaddr *sa, char *host, int cap) {
	host[0] = 0;
	if (!sa) return;
	int len = 0;
	if (sa->sa_family == AF_INET) len = (int)sizeof(struct sockaddr_in);
	else if (sa->sa_family == AF_INET6) len = (int)sizeof(struct sockaddr_in6);
	else return;
	if (getnameinfo(sa, len, host, cap, NULL, 0, NI_NUMERICHOST) != 0) host[0] = 0;
}

// ct_netif_list writes one line per (interface, address) into buf:
// "<IPv4 index>\t<IPv6 index>\t<name>\t<alias>\t<address>\n" — an interface with no address gets
// one line with the address empty; `alias` is Windows' adapter GUID ('' elsewhere). Returns the
// length the lines need (a caller whose buf was shorter asks again), or a negative error code.
static int ct_netif_list(char *buf, int cap) {
	int n = 0;
	char line[2400];
	char host[NI_MAXHOST];
#ifdef _WIN32
	ULONG size = 16384;
	IP_ADAPTER_ADDRESSES *aa = NULL;
	ULONG r = ERROR_BUFFER_OVERFLOW;
	for (int tries = 0; tries < 4 && r == ERROR_BUFFER_OVERFLOW; tries++) {
		free(aa);
		aa = (IP_ADAPTER_ADDRESSES *)malloc(size);
		if (!aa) return -1;
		r = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST
			| GAA_FLAG_SKIP_DNS_SERVER, NULL, aa, &size);
	}
	if (r != NO_ERROR) {
		free(aa);
		return -(int)r;
	}
	for (IP_ADAPTER_ADDRESSES *p = aa; p; p = p->Next) {
		char name[1024] = ""; // a 256-character name as UTF-8
		if (p->FriendlyName)
			WideCharToMultiByte(CP_UTF8, 0, p->FriendlyName, -1, name, (int)sizeof(name), NULL, NULL);
		const char *alias = p->AdapterName ? p->AdapterName : "";
		int any = 0;
		for (IP_ADAPTER_UNICAST_ADDRESS *u = p->FirstUnicastAddress; u; u = u->Next) {
			ct_netif_addr(u->Address.lpSockaddr, host, (int)sizeof(host));
			snprintf(line, sizeof(line), "%lu\t%lu\t%s\t%s\t%s\n", (unsigned long)p->IfIndex,
				(unsigned long)p->Ipv6IfIndex, name, alias, host);
			ct_netif_put(buf, cap, &n, line);
			any = 1;
		}
		if (!any) {
			snprintf(line, sizeof(line), "%lu\t%lu\t%s\t%s\t\n", (unsigned long)p->IfIndex,
				(unsigned long)p->Ipv6IfIndex, name, alias);
			ct_netif_put(buf, cap, &n, line);
		}
	}
	free(aa);
#else
	struct ifaddrs *ifs = NULL;
	if (getifaddrs(&ifs) != 0) return -errno;
	for (struct ifaddrs *a = ifs; a; a = a->ifa_next) {
		if (!a->ifa_name) continue;
		unsigned idx = if_nametoindex(a->ifa_name);
		if (idx == 0) continue;
		ct_netif_addr(a->ifa_addr, host, (int)sizeof(host));
		snprintf(line, sizeof(line), "%u\t%u\t%s\t\t%s\n", idx, idx, a->ifa_name, host);
		ct_netif_put(buf, cap, &n, line);
	}
	freeifaddrs(ifs);
#endif
	return n;
}

// ct_netif_join joins the multicast group `group` (a socket address of `len` bytes, as vlib's
// net.Addr is) on interface `ifindex` with MCAST_JOIN_GROUP, the call Linux, macOS and Windows
// all take for either family; on Linux the socket then hears the group on that interface only
// (IP_MULTICAST_ALL / IPV6_MULTICAST_ALL off). Returns 0, or a negative error code (errno, or Windows' WSA code).
static int ct_netif_join(long long fd, int v6, const void *group, int len, unsigned ifindex) {
	struct group_req g;
	memset(&g, 0, sizeof(g));
	g.gr_interface = ifindex;
	if (len <= 0 || len > (int)sizeof(g.gr_group)) return -1;
	memcpy(&g.gr_group, group, (size_t)len);
#ifdef _WIN32
	if (setsockopt((SOCKET)fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, MCAST_JOIN_GROUP, (const char *)&g,
		(int)sizeof(g)) != 0) return -WSAGetLastError();
#else
	if (setsockopt((int)fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, MCAST_JOIN_GROUP, &g,
		(socklen_t)sizeof(g)) != 0) return -errno;
#ifdef __linux__
	// Linux delivers a group's datagrams from every interface any socket on the host joined it
	// on unless the socket says otherwise: only this socket's own joins count once it is off.
	int off = 0;
	if (setsockopt((int)fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? CT_IPV6_MULTICAST_ALL
		: CT_IP_MULTICAST_ALL, &off, (socklen_t)sizeof(off)) != 0) return -errno;
#endif
#endif
	return 0;
}

// ct_netif_strerror writes the text of an error code ct_netif_list or ct_netif_join returned.
static void ct_netif_strerror(int code, char *buf, int cap) {
	if (cap <= 0) return;
	buf[0] = 0;
#ifdef _WIN32
	// the system's text in UTF-16, converted to UTF-8 as the interface names are
	wchar_t w[512];
	DWORD got = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL,
		(DWORD)code, 0, w, (DWORD)(sizeof(w) / sizeof(w[0])), NULL);
	while (got > 0 && (w[got - 1] == L'\n' || w[got - 1] == L'\r' || w[got - 1] == L'.')) w[--got] = 0;
	int l = got > 0 ? WideCharToMultiByte(CP_UTF8, 0, w, (int)got, buf, cap - 1, NULL, NULL) : 0;
	if (l <= 0) snprintf(buf, (size_t)cap, "error %d", code);
	else buf[l] = 0;
#else
	snprintf(buf, (size_t)cap, "%s", strerror(code));
#endif
}

#endif
