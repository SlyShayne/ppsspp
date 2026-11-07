-- Publishes what the test page shows. Only reads memory.

local RAM_PROBE = 0x08804000 -- where a PSP game's main program usually loads, in user RAM

function update(info)
    publish("frame", info.frame)
    publish("seconds", info.frame // 60)
    publish("ram_hex", string.format("%08X", mem.u32(RAM_PROBE)))
end
