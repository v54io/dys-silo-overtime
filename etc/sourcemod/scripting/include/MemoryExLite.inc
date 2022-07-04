/* thank you internet https://forums.alliedmods.net/showthread.php?t=300627 */
#define Pointer Address
#define nullptr Address_Null

#define int(%1) view_as<int>(%1)
#define ptr(%1) view_as<Pointer>(%1)  

stock int ReadByte(Pointer pAddr)
{
    if(pAddr == nullptr)
    {
        return -1;
    }
    
    return LoadFromAddress(pAddr, NumberType_Int8);
}

stock int ReadWord(Pointer pAddr)
{
    if(pAddr == nullptr)
    {
        return -1;
    }
    
    return LoadFromAddress(pAddr, NumberType_Int16);
}

stock int ReadInt(Pointer pAddr)
{
    if(pAddr == nullptr)
    {
        return -1;
    }
    
    return LoadFromAddress(pAddr, NumberType_Int32);
}

stock Pointer Transpose(Pointer pAddr, int iOffset)
{
    return ptr(int(pAddr) + iOffset);
}

stock int Dereference(Pointer pAddr, int iOffset = 0)
{
    if(pAddr == nullptr)
    {
        return -1;
    }
    
    return ReadInt(Transpose(pAddr, iOffset));
} 

stock Pointer WriteData(Pointer pAddr, int[] data, int iSize)
{
    if(pAddr == nullptr)
    {
        return nullptr;
    }
    
    for(int i = 0; i < iSize; i++)
    {
        StoreToAddress(pAddr, data[i], NumberType_Int8);
        
        pAddr++;
    }
    
    pAddr++;
    
    return pAddr;
}
