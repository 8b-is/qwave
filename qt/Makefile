CXX ?= g++
CXXFLAGS ?= -O2 -Wall -Wextra -std=c++17 -fPIC -I../core/include
QT_FLAGS := $(shell pkg-config --cflags --libs Qt6Widgets Qt6WebEngineWidgets Qt6Network)
RUST_STATICLIB := $(firstword $(wildcard /home/hue/.cargo/target/release/libqwave_core.a ../core/target/release/libqwave_core.a /usr/local/lib/qwave/libqwave_core.a))

qwave-qt: qwave-qt.cpp
	$(CXX) $(CXXFLAGS) qwave-qt.cpp $(RUST_STATICLIB) -o qwave-qt $(QT_FLAGS) -lpthread -ldl -lm

install: qwave-qt
	install -d /usr/local/lib/qwave
	install -m 755 qwave-qt /usr/local/lib/qwave/qwave-qt

clean:
	rm -f qwave-qt
