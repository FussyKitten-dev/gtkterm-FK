/***********************************************************************/
/* device_mintor.h													 */
/* ---------														   */
/*		   GTKTerm Software										  */
/*					  (c) Julien Schmitt							 */
/*																	 */
/* ------------------------------------------------------------------- */
/*																	 */
/*   Purpose														   */
/*	  Monitor device to autoreconnect								*/
/*   Written by Kevin Picot - picotk27@gmail.com					   */
/*																	 */
/***********************************************************************/

#include <device_monitor.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <stdbool.h>
#include <unistd.h>
#include <locale.h>
#include <string.h>
#include <gtk/gtk.h>
#include <glib.h>
#include <interface.h>
#include <term_config.h>
#ifdef HAVE_GUDEV
#include <gudev/gudev.h>
#endif

#include "serial.h"
#include "interface.h"

extern struct configuration_port config;

static inline void device_monitor_status(const bool connected)
{
	if (connected) {
		if (config.autoreconnect_enabled)
			interface_open_port();
	} else
		interface_close_port();
}

static inline void device_monitor_handle(const char *action)
{
	if (strcmp(action, "remove") == 0)
		device_monitor_status(false);
	else if (strcmp(action, "add") == 0)
		device_monitor_status(true);
}

#ifdef HAVE_GUDEV
void event_udev(GUdevClient *client, const gchar *action, GUdevDevice *device)
{

	if (!device || !action)
		return;

	if (!g_udev_device_get_device_file(device))
		return;

	const gchar *name = config.port;

	if (strcmp(g_udev_device_get_device_file(device), name) == 0)
		device_monitor_handle(action);
}
#endif /* HAVE_GUDEV */

#ifndef HAVE_GUDEV
/* Polling-based fallback for platforms without udev (e.g. macOS).
 * Each second, derives the desired action from the actual port fd state
 * vs device presence — no transition tracking needed, so it is self-healing
 * if a reconnect attempt fails (e.g. device not yet ready). */
static gboolean device_monitor_poll(gpointer user_data)
{
	(void)user_data;

	gboolean present = (access(config.port, F_OK) == 0);
	gboolean port_open = (serial_port_fd != -1);

	if (present && !port_open) {
		/* Device (re)appeared and port is closed — try to open */
		device_monitor_status(true);
	} else if (!present && port_open) {
		/* Device removed and port is still open — close it */
		device_monitor_status(false);
	}

	return G_SOURCE_CONTINUE;
}
#endif /* !HAVE_GUDEV */

extern void device_monitor_start(void)
{
#ifdef HAVE_GUDEV
	const gchar *const subsystems[] = {NULL, NULL};

	/* Initial check */
	GUdevClient *udev_client = g_udev_client_new(subsystems);

	if (g_udev_client_query_by_device_file(udev_client, config.port) == NULL) {
		device_monitor_status(false);
	} else {
		device_monitor_status(true);
	}

	/* Monitor device */
	g_signal_connect(G_OBJECT(udev_client), "uevent",
	                 G_CALLBACK(event_udev), NULL);
#else
	/* Polling fallback: initial state + 1-second poll via GLib main loop */
	device_monitor_status((bool)(access(config.port, F_OK) == 0));
	g_timeout_add_seconds(1, device_monitor_poll, NULL);
#endif /* HAVE_GUDEV */
}
