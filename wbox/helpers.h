#pragma once

#ifndef id_26FCBE24_1243_4829_89F4_B266B158236E
#define id_26FCBE24_1243_4829_89F4_B266B158236E

#include <windows.h>
#include <exception>
#include <string>

class AutoHandle {
	HANDLE handle;
public:
	AutoHandle() : handle(nullptr) {}
	explicit AutoHandle(HANDLE h) : handle(h) {}
	~AutoHandle() { CloseHandle(handle); }
	operator HANDLE() { return handle; }
	HANDLE get() { return handle; }
	void set(HANDLE h) { *this = h; }

	AutoHandle &operator=(HANDLE h) {
		if (handle)
			CloseHandle(handle);
		handle = h;
		return *this;
	}

	HANDLE detach() {
		HANDLE h = handle;
		handle = nullptr;
		return h;
	}

	void close() {
		CloseHandle(handle);
		handle = nullptr;
	}
};

class SeDebugPrivilege {
	HANDLE hToken;
	TOKEN_PRIVILEGES tp;
public:
	SeDebugPrivilege();
	~SeDebugPrivilege();
};

std::string FormatWindowsError(DWORD error);

class WindowsException : public std::exception {
	DWORD error;
	mutable char message[1024];
	const char *location;
public:
	WindowsException(const char* location);
	WindowsException(const char* location, DWORD error);
	const char* what() const override;
	DWORD code() { return error; }
};

class HRException : public std::exception {
	HRESULT error;
	mutable char message[1024];
	const char *location;
public:
	HRException(const char* location, HRESULT error);
	const char* what() const override;
	HRESULT code() { return error; }
};

#endif