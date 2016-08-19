#!/usr/bin/env python

places = [
    (1000000000000, 'trillion'),
    (1000000000, 'billion'),
    (1000000, 'million'),
    (1000, 'thousand'),
    (1, '')
]

ones = {
    0: '',
    1: 'one',
    2: 'two',
    3: 'three',
    4: 'four',
    5: 'five',
    6: 'six',
    7: 'seven',
    8: 'eight',
    9: 'nine',
    10: 'ten',
    11: 'eleven',
    12: 'twelve',
    13: 'thirteen',
    14: 'fourteen',
    15: 'fifteen',
    16: 'sixteen',
    17: 'seventeen',
    18: 'eighteen',
    19: 'nineteen',
}

tens = {
    0: '',
    1: '',
    2: 'twenty',
    3: 'thirty',
    4: 'fourty',
    5: 'fifty',
    6: 'sixty',
    7: 'seventy',
    8: 'eighty',
    9: 'ninety',
}

def write_check(amount):
    """
    Write a check in English based on numeric input.

    Arguments:
    - amount: an instance of decimal.Decimal representing the monetary input.

    Returns a string with the English output.

    Example:

    import decimal

    amount = decimal.Decimal('67213.21')
    write_check(amount)

    ===> 'sixty seven thousand two hundred thirteen and 21/100 dollars'
    """
    def _write_check(amount, places=places, s=[]):
        if amount < 1:
            return s + ['and' if s else '', '{}/100'.format(int(amount*100)), 'dollars']
        place, eng_place = places[0]
        cur = amount / place
        new_s = [] if cur < 1 else do_hundreds(int(cur)) + [eng_place]
        return _write_check(amount % place, places[1:], s + new_s)
    return ' '.join(s for s in _write_check(amount) if s)

def do_hundreds(amount, div=100, eng=ones, s=[]):
    if not amount: return s
    if amount > 100:
        eng_place = 'hundred'
        eng = ones
    else:
        eng_place = ''
        if amount >= 20:
            eng = tens
        else:
            return s + [ones[amount]]
    new_s = s + [eng[int(amount / div)], eng_place]
    return do_hundreds(amount % div, div / 10, eng=eng, s=new_s)
