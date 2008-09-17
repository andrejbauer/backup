# Create a distribution

# Please increase this every time
VERSION=0.1

default: distribution

distribution:
	cd .. && \
	zip -r backup-$(VERSION).zip backup -x "backup/.svn/*" -x "backup/private/*" -x backup/Makefile
