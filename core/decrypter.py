from Crypto.Cipher import AES

class Decrypter:
    @staticmethod
    def sequence_iv(sequence: int) -> bytes:
        """RFC 8216: EXT-X-KEY 未声明 IV 时，缺省 IV = 该切片的 media sequence number。
        16 字节大端（高位补零）。iOS 侧 Downloader.sequenceIV 同步（2026-11-14）——
        旧实现缺省全 0 IV，无 IV 的加密流解密错误。"""
        seq = max(0, sequence)
        if seq >= 1 << 64:
            raise ValueError(f"media sequence 超出 64 位: {seq}")
        return seq.to_bytes(16, "big")

    @staticmethod
    def decrypt_aes_128(content, key, iv=None):
        """
        AES-128-CBC 解密
        :param content: 密文
        :param key: 密钥 (bytes)
        :param iv: 初始化向量 (bytes), 可选
        :return: 明文
        """
        if not iv:
             # 全 0 兜底：调用方应按 RFC 8216 传 media sequence number 派生的 IV
             #（见 sequence_iv）；规范未定义 IV 与序列号挂钩前的旧流可能依赖全 0。
             iv = b'\x00' * 16

        cipher = AES.new(key, AES.MODE_CBC, iv)
        return cipher.decrypt(content)
