#pragma once

#include <CoreVideo/CoreVideo.h>
#include "DeckLinkAPI.h"
#include <stdatomic.h>
#include <Metal/Metal.h>

class DeckLinkMetalBufferFrame : public IDeckLinkVideoFrame
{
public:
	DeckLinkMetalBufferFrame(id<MTLBuffer> imageBuffer);
	
protected:
	virtual ~DeckLinkMetalBufferFrame();
	
public:
	// IDeckLinkVideoFrame
	virtual long GetWidth(void);
	virtual long GetHeight(void);
	virtual long GetRowBytes(void);
	virtual BMDPixelFormat GetPixelFormat(void);
	virtual void SetWidth(long);
	virtual void SetHeight(long);
	virtual void SetRowBytes(long);
	virtual void SetPixelFormat(BMDPixelFormat);

	virtual BMDFrameFlags GetFlags(void);
	virtual void setFlags(BMDFrameFlags);
	virtual HRESULT GetBytes(void **buffer);
	
	virtual HRESULT GetTimecode(BMDTimecodeFormat format, IDeckLinkTimecode **timecode);
	virtual HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary **ancillary);
	
	// IUnknown
	virtual HRESULT QueryInterface(REFIID iid, LPVOID *ppv);
	virtual ULONG AddRef(void);
	virtual ULONG Release(void);
	
private:
	id<MTLBuffer> metalBuffer;
	bool locked;
	atomic_int refCount;
	BMDFrameFlags frameFlags;
	uint32_t pixelformat;
	long width;
	long height;
	long rowbytes;
};
