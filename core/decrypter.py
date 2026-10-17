from Crypto.Cipher import AES

class Decrypter:
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
             # 如果没有提供 IV，使用全 0 填充 (视具体实现而定，有时需要从序列号生成)
             iv = b'\x00' * 16 

        cipher = AES.new(key, AES.MODE_CBC, iv)
        return cipher.decrypt(content)
