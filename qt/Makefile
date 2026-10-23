CXX ?= g++
CXXFLAGS ?= -O2 -Wall -Wextra -std=c++17 -fPIC
QT_FLAGS := $(shell pkg-config --cflags --libs Qt6Widgets Qt6WebEngineWidgets)

qwave-qt: qwave-qt.cpp
	$(CXX) $(CXXFLAGS) qwave-qt.cpp -o qwave-qt $(QT_FLAGS)

install: qwave-qt
	install -d /usr/local/lib/qwave
	install -m 755 qwave-qt /usr/local/lib/qwave/qwave-qt

clean:
	rm -f qwave-qt
