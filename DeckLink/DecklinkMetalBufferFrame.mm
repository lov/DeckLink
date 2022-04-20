#include "DeckLinkMetalBufferFrame.h"

#include <stdatomic.h>

DeckLinkMetalBufferFrame::DeckLinkMetalBufferFrame(id<MTLBuffer> metalBuffer) :
metalBuffer(metalBuffer),
locked(false),
frameFlags(bmdFrameFlagDefault),
refCount(1)
{
}

DeckLinkMetalBufferFrame::~DeckLinkMetalBufferFrame()
{
}

long DeckLinkMetalBufferFrame::GetWidth(void)
{
	return width;
}

long DeckLinkMetalBufferFrame::GetHeight(void)
{
	return height;
}

long DeckLinkMetalBufferFrame::GetRowBytes(void)
{
	return rowbytes;
}

BMDPixelFormat DeckLinkMetalBufferFrame::GetPixelFormat(void)
{
	return pixelformat;
}

void DeckLinkMetalBufferFrame::SetWidth(long _width)
{
	width = _width;
}

void DeckLinkMetalBufferFrame::SetHeight(long _height)
{
	height = _height;
}

void DeckLinkMetalBufferFrame::SetRowBytes(long _rowbytes)
{
	rowbytes = _rowbytes;
}

void DeckLinkMetalBufferFrame::SetPixelFormat(BMDPixelFormat _pixelformat)
{
	pixelformat = _pixelformat;
}


BMDFrameFlags DeckLinkMetalBufferFrame::GetFlags(void)
{
	return frameFlags;
}

HRESULT DeckLinkMetalBufferFrame::GetBytes(void **buffer)
{

	*buffer = [metalBuffer contents];
	return S_OK;

}

HRESULT DeckLinkMetalBufferFrame::GetTimecode(BMDTimecodeFormat format, IDeckLinkTimecode **timecode)
{
	// TODO:
	return E_FAIL;
}

HRESULT DeckLinkMetalBufferFrame::GetAncillaryData(IDeckLinkVideoFrameAncillary **ancillary)
{
	// TODO:
	return E_FAIL;
}

HRESULT DeckLinkMetalBufferFrame::QueryInterface(REFIID iid, LPVOID *ppv)
{
	*ppv = NULL;
	
	CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
	if(memcmp(&iid, &iunknown, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		return S_OK;
	}
	
	if(memcmp(&iid, &IID_IDeckLinkVideoFrame, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		return S_OK;
	}
	
	return E_NOINTERFACE;
}


void DeckLinkMetalBufferFrame::setFlags(BMDFrameFlags flag)
{
	frameFlags = flag;
	
}

ULONG DeckLinkMetalBufferFrame::AddRef(void)
{
	return atomic_fetch_add(&refCount, 1);
}

ULONG DeckLinkMetalBufferFrame::Release(void)
{
	int32_t oldRefValue = atomic_fetch_add(&refCount, -1);	// Note: atomic_fetch_add() returns the previous value
	int32_t newRefValue = oldRefValue - 1;
	
	if(newRefValue == 0)
	{
		delete this;
		return 0;
	}
	
	return newRefValue;
}
