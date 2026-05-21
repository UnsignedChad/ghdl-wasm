ortho_srcdir=..
GNATMAKE=gnatmake
GNATFLAGS=-gnata -gnatf -gnatwlcru
CC=gcc
BE=wasm
SED=sed
ORTHO_BASENAME=ortho_wasm

all: $(ortho_srcdir)/$(BE)/$(ORTHO_BASENAME).ads

$(ortho_srcdir)/$(BE)/$(ORTHO_BASENAME).ads: \
  $(ortho_srcdir)/ortho_nodes.common.ads \
  $(ortho_srcdir)/$(BE)/$(ORTHO_BASENAME).private.ads
	$(RM) -f $@
	echo "--  DO NOT MODIFY - this file was generated from:" > $@
	echo "--  ortho_nodes.common.ads and $(ORTHO_BASENAME).private.ads" >> $@
	echo "--" >> $@
	$(SED) -e '/^private/,$$d' \
	  < $(ortho_srcdir)/$(BE)/$(ORTHO_BASENAME).private.ads >> $@
	echo "--  Start of common part" >> $@
	$(SED) -e '1,/^package/d' -e '/^private/,$$d' \
	  < $(ortho_srcdir)/ortho_nodes.common.ads >> $@
	echo "--  End of common part" >> $@
	$(SED) -n -e '/^private/,$$p' \
	  < $(ortho_srcdir)/$(BE)/$(ORTHO_BASENAME).private.ads >> $@
	chmod a-w $@

clean:
	$(RM) -f *.o *.ali $(ORTHO_BASENAME).ads

.PHONY: all clean
