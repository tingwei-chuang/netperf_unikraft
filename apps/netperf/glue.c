#include <stdio.h>
#include <string.h>

int netserver_main(int argc, char *argv[]);

int main(int argc, char *argv[])
{
	/*
	 * Forward kernel command-line args if provided; otherwise use defaults:
	 *   -D  foreground (no daemon/fork)
	 *   -f  no spawn-on-accept (single-threaded accept loop)
	 *   -4  IPv4 only
	 *   -p 12865  standard netperf control port
	 */
	if (argc > 1)
		return netserver_main(argc, argv);

	char *defargv[] = {
		"netserver", "-D", "-f", "-4", "-p", "12865", NULL
	};
	return netserver_main(6, defargv);
}
