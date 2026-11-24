import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('private_credentials', Path(__file__).parents[1] / 'prepare-private-credentials.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class PrivateCredentialsTests(unittest.TestCase):
    def test_requires_both_independent_voice_credentials(self):
        for values in ({}, {'seed': 'fixture'}, {'ark': 'fixture'}):
            with self.assertRaises(ValueError):
                module.validate(values)

    def test_rejects_invalid_values_without_echoing_secrets(self):
        for bad in ('secret fixture', 'secret\nfixture', ['secret'], 's' * 8193):
            with self.assertRaises(ValueError) as error:
                module.validate({'seed': bad, 'ark': 'fixture-ark'})
            self.assertNotIn('secret', str(error.exception))

    def test_optional_provider_keys_stay_separate(self):
        values = module.validate({'seed': 'fixture-seed', 'ark': 'fixture-ark'})
        self.assertEqual(values['seed'], 'fixture-seed')
        self.assertEqual(values['ark'], 'fixture-ark')
        self.assertEqual(values['openai'], '')
        self.assertEqual(values['openrouter'], '')
